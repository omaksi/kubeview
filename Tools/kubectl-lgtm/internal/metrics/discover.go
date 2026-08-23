package metrics

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	promapi "github.com/prometheus/client_golang/api"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

// probeTimeout bounds one candidate's PromQL check. It is short on purpose:
// the cost of being wrong is trying the next candidate, and a long timeout
// turns a bad guess into a minute of a dead-looking terminal.
const probeTimeout = 8 * time.Second

// candidate is one Service that might answer PromQL.
type candidate struct {
	namespace string
	service   string
	port      int32
	portName  string
	// prefix is the path the query API lives under. Mimir's gateway serves it
	// at /prometheus; a plain Prometheus serves it at the root.
	prefix string
	rank   int
	why    string
}

func (c candidate) String() string {
	return fmt.Sprintf("%s/%s:%d%s", c.namespace, c.service, c.port, c.prefix)
}

// matchers is consulted in order; the first hit wins and sets the rank.
//
// This is an allow-list and it has to be exact. The first live run matched
// "prometheus" as a substring and adopted five kube-prometheus-stack scrape
// targets — coredns, kube-proxy, kube-etcd, kube-scheduler,
// kube-controller-manager — none of which serve PromQL. The release name
// prefixes those Services, so only a suffix match distinguishes the real
// Prometheus from the things it scrapes.
//
// The Mimir gateway outranks its query-frontend deliberately: the gateway
// injects a default X-Scope-OrgID, so multi-tenant Mimir answers without the
// caller holding a tenant. Going straight to the query-frontend returns 401
// unless --tenant is set.
var matchers = []struct {
	contains []string
	suffix   []string
	exclude  []string
	prefix   string
	rank     int
	why      string
}{
	{contains: []string{"mimir-nginx", "mimir-gateway", "cortex-nginx"},
		prefix: "/prometheus", rank: 0, why: "Mimir gateway"},
	{contains: []string{"thanos-query", "thanos-querier"}, exclude: []string{"frontend"},
		prefix: "", rank: 1, why: "Thanos query"},
	{suffix: []string{"prometheus", "prometheus-server", "prometheus-operated", "victoriametrics"},
		exclude: []string{"node-exporter", "kube-state", "operator", "alertmanager", "pushgateway", "json-exporter"},
		prefix:  "", rank: 2, why: "Prometheus"},
	{contains: []string{"mimir-query-frontend", "cortex-query-frontend"},
		prefix: "/prometheus", rank: 3, why: "Mimir query-frontend"},
}

func classifyService(svc corev1.Service) (candidate, bool) {
	name := strings.ToLower(svc.Name)
	for _, m := range matchers {
		if len(m.contains) > 0 && !anyContains(name, m.contains) {
			continue
		}
		if len(m.suffix) > 0 && !anySuffix(name, m.suffix) {
			continue
		}
		if anyContains(name, m.exclude) {
			continue
		}
		port, portName, ok := servicePort(svc)
		if !ok {
			continue
		}
		return candidate{
			namespace: svc.Namespace,
			service:   svc.Name,
			port:      port,
			portName:  portName,
			prefix:    m.prefix,
			rank:      m.rank,
			why:       m.why,
		}, true
	}
	return candidate{}, false
}

func anyContains(s string, subs []string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

func anySuffix(s string, sufs []string) bool {
	for _, suf := range sufs {
		if strings.HasSuffix(s, suf) {
			return true
		}
	}
	return false
}

// servicePort picks the HTTP port. Named ports win over ordinal position
// because a Mimir gateway exposes both HTTP and gRPC.
func servicePort(svc corev1.Service) (int32, string, bool) {
	var first corev1.ServicePort
	var found bool
	for _, p := range svc.Spec.Ports {
		if p.Protocol != "" && p.Protocol != corev1.ProtocolTCP {
			continue
		}
		if !found {
			first, found = p, true
		}
		switch strings.ToLower(p.Name) {
		case "http", "http-metrics", "http-web", "web", "api":
			return p.Port, p.Name, true
		}
	}
	return first.Port, first.Name, found
}

// endpointPort finds the resolved container port for a Service port name.
func endpointPort(ports []corev1.EndpointPort, name string) (int32, bool) {
	if len(ports) == 1 {
		return ports[0].Port, true
	}
	for _, p := range ports {
		if p.Name == name {
			return p.Port, true
		}
	}
	if len(ports) > 0 {
		return ports[0].Port, true
	}
	return 0, false
}

// tenantTransport adds Mimir's tenant header, for talking straight to a
// query-frontend that has no gateway in front of it to supply a default.
type tenantTransport struct {
	base   http.RoundTripper
	tenant string
}

func (t tenantTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.Header.Set("X-Scope-OrgID", t.tenant)
	return t.base.RoundTrip(req)
}

// Discover finds a query endpoint and returns a Provider plus a closer that
// tears down the port-forward it opened.
//
// An explicit --prom-url short-circuits everything, which keeps a path open
// for anyone who cannot port-forward or who has a metrics store outside the
// cluster entirely.
func Discover(ctx context.Context, cs kubernetes.Interface, restCfg *rest.Config, cfg config.Config, progress func(string)) (*Prometheus, func(), error) {
	noop := func() {}
	if cfg.PromURL != "" {
		p, err := NewPrometheus(cfg)
		return p, noop, err
	}

	var rt http.RoundTripper = http.DefaultTransport
	if cfg.Tenant != "" {
		rt = tenantTransport{base: rt, tenant: cfg.Tenant}
	}

	cands, seen, err := findCandidates(ctx, cs, cfg)
	if err != nil {
		return nil, noop, err
	}
	if len(cands) == 0 {
		return nil, noop, fmt.Errorf("no metrics endpoint found in %s of %s\n\n"+
			"looked for a Mimir gateway, Thanos query or Prometheus service among the\n"+
			"%d services there, and found none\n\n"+
			"a cluster that only runs collectors (Grafana Alloy, an OTel agent) ships its\n"+
			"metrics to a store somewhere else — analyse the cluster that holds the store",
			scopeLabel(cfg), contextLabel(cfg), seen)
	}

	var tried []string
	for _, c := range cands {
		progress(fmt.Sprintf("trying %s (%s)", c, c.why))

		fw, err := startForward(ctx, cs, restCfg, c)
		if err != nil {
			tried = append(tried, fmt.Sprintf("  %s — %v", c, err))
			continue
		}

		p, err := probe(ctx, fmt.Sprintf("http://127.0.0.1:%d%s", fw.local, c.prefix), rt, cfg, c)
		if err != nil {
			fw.Close()
			tried = append(tried, fmt.Sprintf("  %s — %v", c, err))
			continue
		}
		return p, fw.Close, nil
	}

	return nil, noop, fmt.Errorf("in %s of %s, found %d candidate endpoint(s), none answered PromQL:\n%s\n\n"+
		"if the store is multi-tenant it may be rejecting an unauthenticated read",
		scopeLabel(cfg), contextLabel(cfg), len(cands), strings.Join(tried, "\n"))
}

// findCandidates lists Services in scope and keeps the recognised ones. It also
// reports how many it looked at, so "found nothing" can distinguish an empty
// namespace from one full of services that simply do not serve PromQL.
func findCandidates(ctx context.Context, cs kubernetes.Interface, cfg config.Config) ([]candidate, int, error) {
	namespaces := cfg.Namespaces
	if len(namespaces) == 0 {
		namespaces = []string{metav1.NamespaceAll}
	}

	var out []candidate
	var seen int
	for _, ns := range namespaces {
		list, err := cs.CoreV1().Services(ns).List(ctx, metav1.ListOptions{})
		if err != nil {
			if apierrors.IsForbidden(err) && ns == metav1.NamespaceAll {
				return nil, 0, fmt.Errorf("listing services cluster-wide is forbidden for this account; " +
					"narrow the analysis to one namespace")
			}
			return nil, 0, fmt.Errorf("list services in %q: %w", ns, err)
		}
		seen += len(list.Items)
		for _, svc := range list.Items {
			if c, ok := classifyService(svc); ok {
				out = append(out, c)
			}
		}
	}

	sort.SliceStable(out, func(i, j int) bool { return out[i].rank < out[j].rank })
	return out, seen, nil
}

// probe verifies a candidate actually speaks PromQL before it is adopted.
//
// Name matching alone is not enough — a Loki gateway looks similar and 404s on
// /api/v1/query — and a wrong endpoint fails silently by returning zero for
// every rule, which renders identically to a healthy stack.
func probe(ctx context.Context, addr string, rt http.RoundTripper, cfg config.Config, c candidate) (*Prometheus, error) {
	client, err := promapi.NewClient(promapi.Config{Address: addr, RoundTripper: rt})
	if err != nil {
		return nil, err
	}
	api := promv1.NewAPI(client)

	probeCtx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	if _, _, err := api.Query(probeCtx, "vector(1)", time.Now()); err != nil {
		return nil, err
	}

	desc := fmt.Sprintf("%s/%s (%s)", c.namespace, c.service, c.why)
	return &Prometheus{api: api, cfg: cfg, desc: desc, warn: clusterWarning(ctx, api, cfg)}, nil
}

// clusterWarning flags a store that holds more than one cluster.
//
// Namespace and pod names repeat across clusters, so every aggregation the
// rules run silently spans them — a component's memory can come back as the
// max across four clusters and look exactly like a legitimate number. This
// only reports; auto-selecting a cluster from the kube context would be a
// guess, and a wrong guess here is invisible.
func clusterWarning(ctx context.Context, api promv1.API, cfg config.Config) string {
	if strings.Contains(cfg.Match, "cluster") {
		return ""
	}

	qctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()

	// Ask the metric the rules actually aggregate, not `up`: on a Mimir fed by
	// Grafana Alloy the `up` series carries no cluster label at all, so
	// counting clusters through it silently returns nothing and the warning
	// never fires. cAdvisor series do carry it.
	end := time.Now()
	vals, _, err := api.LabelValues(qctx, "cluster",
		[]string{cfg.Metrics.MemWorkingSet}, end.Add(-cfg.Window), end)
	if err != nil || len(vals) <= 1 {
		return ""
	}

	names := make([]string, 0, len(vals))
	for _, v := range vals {
		names = append(names, string(v))
	}
	sort.Strings(names)
	return fmt.Sprintf("this store holds %d clusters (%s), and every number here is "+
		"aggregated across all of them — a peak from a busier cluster is "+
		"indistinguishable from this one's",
		len(names), strings.Join(names, ", "))
}

func scopeLabel(cfg config.Config) string {
	if len(cfg.Namespaces) == 0 {
		return "any namespace"
	}
	return "ns/" + strings.Join(cfg.Namespaces, ",")
}

// contextLabel names the cluster being analysed. Every failure has to carry it:
// the tool is pointed at one cluster and queries another'\”s data, and an error
// that omits which cluster it ran against costs an investigation to recover.
func contextLabel(cfg config.Config) string {
	if cfg.Context == "" {
		return "the current context"
	}
	return "context " + cfg.Context
}
