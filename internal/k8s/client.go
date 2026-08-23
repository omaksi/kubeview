package k8s

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

// Client is a read-only view of the cluster. It never mutates anything; the
// user or ServiceAccount it runs as needs only get/list/watch.
type Client struct {
	cs kubernetes.Interface
	// restCfg is retained so the metrics layer can reach a Service through the
	// API server's proxy, reusing this connection's auth and TLS.
	restCfg *rest.Config
	cfg     config.Config
	clf     *Classifier

	// defaultNS is the kubeconfig context's namespace, used as the fallback
	// when a cluster-wide list is forbidden.
	defaultNS string

	mu    sync.Mutex
	scope string
}

// New builds a client from the usual kubeconfig resolution rules, honouring
// --kubeconfig and --context.
func New(cfg config.Config) (*Client, error) {
	if cfg.Selector != "" {
		if _, err := labels.Parse(cfg.Selector); err != nil {
			return nil, fmt.Errorf("invalid --selector %q: %w", cfg.Selector, err)
		}
	}

	clf, err := NewClassifier(cfg.Classify)
	if err != nil {
		return nil, err
	}

	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if cfg.Kubeconfig != "" {
		rules.ExplicitPath = cfg.Kubeconfig
	}
	overrides := &clientcmd.ConfigOverrides{}
	if cfg.Context != "" {
		overrides.CurrentContext = cfg.Context
	}
	clientCfg := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, overrides)

	restCfg, err := clientCfg.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("load kubeconfig: %w", err)
	}
	cs, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return nil, fmt.Errorf("build clientset: %w", err)
	}

	defaultNS, _, _ := clientCfg.Namespace()

	return &Client{
		cs:        cs,
		restCfg:   restCfg,
		cfg:       cfg,
		clf:       clf,
		defaultNS: defaultNS,
		scope:     cfg.NamespaceLabel(),
	}, nil
}

// Clientset exposes the read-only API client for endpoint discovery.
func (c *Client) Clientset() kubernetes.Interface { return c.cs }

// RestConfig exposes the resolved connection, so the metrics layer can build a
// transport that talks to the API server with the same credentials.
func (c *Client) RestConfig() *rest.Config { return c.restCfg }

// Contexts lists the contexts in the merged kubeconfig, plus the current one.
//
// The loading rules already merge every file in $KUBECONFIG with ~/.kube/config,
// so "scan for kubeconfigs" is the default behaviour rather than something this
// tool implements.
func Contexts(kubeconfig string) (names []string, current string, err error) {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if kubeconfig != "" {
		rules.ExplicitPath = kubeconfig
	}
	raw, err := rules.Load()
	if err != nil {
		return nil, "", fmt.Errorf("load kubeconfig: %w", err)
	}
	for name := range raw.Contexts {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, raw.CurrentContext, nil
}

// ProductNamespaces reports the namespaces that actually contain recognised
// LGTM components.
//
// This is what lets the bare binary narrow its own scope: where the stack sits
// in one namespace there is nothing worth asking, and where it is split across
// several the operator picks once instead of having to know to pass -n. It
// ignores cfg.All deliberately — an unrecognised workload is not evidence that
// a namespace holds the stack.
func (c *Client) ProductNamespaces(ctx context.Context) ([]string, error) {
	comps, err := c.listIn(ctx, metav1.NamespaceAll)
	if err != nil {
		if !apierrors.IsForbidden(err) || c.defaultNS == "" {
			return nil, err
		}
		// Cluster-wide list forbidden: the kubeconfig namespace is the only
		// scope available, so there is nothing to choose between.
		return []string{c.defaultNS}, nil
	}

	seen := map[string]bool{}
	var out []string
	for _, comp := range comps {
		if comp.Product == ProductUnknown || seen[comp.Namespace] {
			continue
		}
		seen[comp.Namespace] = true
		out = append(out, comp.Namespace)
	}
	sort.Strings(out)
	return out, nil
}

// Describe reports the scope actually searched, which is not always the scope
// requested — a cluster-wide list can fall back to a single namespace.
func (c *Client) Describe() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.scope
}

func (c *Client) setScope(s string) {
	c.mu.Lock()
	c.scope = s
	c.mu.Unlock()
}

// ListComponents discovers workloads across the configured scope and
// classifies them.
//
// With no namespace configured it searches the whole cluster, because an LGTM
// stack is as likely to be split across mimir/loki/tempo namespaces as it is to
// sit in one. When that is forbidden it falls back to the kubeconfig's
// namespace and says so rather than reporting an empty stack.
func (c *Client) ListComponents(ctx context.Context) ([]Component, error) {
	nss := c.cfg.Namespaces

	if len(nss) == 0 {
		comps, err := c.listIn(ctx, metav1.NamespaceAll)
		switch {
		case err == nil:
			c.setScope("all namespaces")
			return c.finalize(comps), nil
		case !apierrors.IsForbidden(err) || c.defaultNS == "":
			return nil, err
		}

		comps, ferr := c.listIn(ctx, c.defaultNS)
		if ferr != nil {
			return nil, fmt.Errorf("cluster-wide list forbidden, and %w", ferr)
		}
		c.setScope(fmt.Sprintf("ns/%s (cluster-wide list forbidden)", c.defaultNS))
		return c.finalize(comps), nil
	}

	var all []Component
	for _, ns := range nss {
		comps, err := c.listIn(ctx, ns)
		if err != nil {
			return nil, err
		}
		all = append(all, comps...)
	}
	c.setScope(c.cfg.NamespaceLabel())
	return c.finalize(all), nil
}

// listIn lists every configured kind in one namespace.
func (c *Client) listIn(ctx context.Context, ns string) ([]Component, error) {
	opts := metav1.ListOptions{LabelSelector: c.cfg.Selector}
	var out []Component

	if c.wantKind("Deployment") {
		list, err := c.cs.AppsV1().Deployments(ns).List(ctx, opts)
		if err != nil {
			return nil, c.listError("deployments", ns, err)
		}
		for i := range list.Items {
			d := &list.Items[i]
			comp := c.newComponent(d.Name, d.Namespace, "Deployment", d.Labels,
				d.Status.ReadyReplicas, d.Spec.Replicas, d.Spec.Template.Spec.Containers)
			out = append(out, comp)
		}
	}

	if c.wantKind("StatefulSet") {
		list, err := c.cs.AppsV1().StatefulSets(ns).List(ctx, opts)
		if err != nil {
			return nil, c.listError("statefulsets", ns, err)
		}
		for i := range list.Items {
			s := &list.Items[i]
			comp := c.newComponent(s.Name, s.Namespace, "StatefulSet", s.Labels,
				s.Status.ReadyReplicas, s.Spec.Replicas, s.Spec.Template.Spec.Containers)
			out = append(out, comp)
		}
	}

	if c.wantKind("DaemonSet") {
		list, err := c.cs.AppsV1().DaemonSets(ns).List(ctx, opts)
		if err != nil {
			return nil, c.listError("daemonsets", ns, err)
		}
		for i := range list.Items {
			d := &list.Items[i]
			out = append(out, c.newDaemonSet(d))
		}
	}

	return out, nil
}

func (c *Client) listError(kind, ns string, err error) error {
	scope := fmt.Sprintf("namespace %q", ns)
	if ns == metav1.NamespaceAll {
		scope = "all namespaces"
	}
	return fmt.Errorf("list %s in %s: %w", kind, scope, err)
}

func (c *Client) newComponent(name, ns, kind string, lbls map[string]string,
	ready int32, replicas *int32, containers []corev1.Container) Component {

	comp := Component{
		Name:          name,
		Namespace:     ns,
		Kind:          kind,
		ReadyReplicas: ready,
		Containers:    containersOf(containers),
	}
	if replicas != nil {
		comp.Replicas = *replicas
	}
	comp.Product, comp.Role, comp.Zone = c.clf.Classify(ns, name, lbls)
	comp.PodPattern = PodPattern(c.cfg, kind, name)
	return comp
}

// newDaemonSet maps a DaemonSet's node counts onto the replica fields, so the
// READY column means the same thing for every kind.
func (c *Client) newDaemonSet(d *appsv1.DaemonSet) Component {
	comp := Component{
		Name:          d.Name,
		Namespace:     d.Namespace,
		Kind:          "DaemonSet",
		Replicas:      d.Status.DesiredNumberScheduled,
		ReadyReplicas: d.Status.NumberReady,
		Containers:    containersOf(d.Spec.Template.Spec.Containers),
	}
	comp.Product, comp.Role, comp.Zone = c.clf.Classify(d.Namespace, d.Name, d.Labels)
	comp.PodPattern = PodPattern(c.cfg, "DaemonSet", d.Name)
	return comp
}

func (c *Client) wantKind(kind string) bool {
	if len(c.cfg.Kinds) == 0 {
		return true
	}
	for _, k := range c.cfg.Kinds {
		if strings.EqualFold(k, kind) {
			return true
		}
	}
	return false
}

// finalize drops unclassified workloads unless --all was passed, then sorts.
func (c *Client) finalize(in []Component) []Component {
	out := in
	if !c.cfg.All {
		out = in[:0]
		for _, comp := range in {
			if comp.Product != ProductUnknown {
				out = append(out, comp)
			}
		}
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Product != out[j].Product {
			return out[i].Product < out[j].Product
		}
		if out[i].Namespace != out[j].Namespace {
			return out[i].Namespace < out[j].Namespace
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// PodPattern builds the regex matching a workload's pods.
//
// PromQL anchors regex matchers, so the kind-aware patterns below cannot bleed
// across workloads whose names prefix one another: `loki-ingester-[0-9]+` does
// not match `loki-ingester-zone-a-0`. The loose prefix form does, which is why
// it is no longer the default.
func PodPattern(cfg config.Config, kind, name string) string {
	if p, ok := cfg.PodMatchOverrides[name]; ok {
		return p
	}
	q := regexp.QuoteMeta(name)

	if cfg.PodMatch == config.PodMatchPrefix {
		return q + "-.*"
	}

	switch kind {
	case "StatefulSet":
		// <name>-<ordinal>
		return q + "-[0-9]+"
	case "Deployment":
		// <name>-<replicaset-hash>-<pod-suffix>
		return q + "-[a-z0-9]+-[a-z0-9]+"
	case "DaemonSet":
		// <name>-<pod-suffix>
		return q + "-[a-z0-9]+"
	default:
		return q + "-.*"
	}
}

func containersOf(cs []corev1.Container) []Container {
	out := make([]Container, 0, len(cs))
	for _, c := range cs {
		ct := Container{Name: c.Name}
		if q := c.Resources.Requests.Cpu(); q != nil {
			ct.CPURequest = q.MilliValue()
		}
		if q := c.Resources.Limits.Cpu(); q != nil {
			ct.CPULimit = q.MilliValue()
		}
		if q := c.Resources.Requests.Memory(); q != nil {
			ct.MemRequest = q.Value()
		}
		if q := c.Resources.Limits.Memory(); q != nil {
			ct.MemLimit = q.Value()
		}
		out = append(out, ct)
	}
	return out
}
