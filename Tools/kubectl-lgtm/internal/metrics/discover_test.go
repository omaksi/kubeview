package metrics

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/omaksi/kubectl-lgtm/internal/config"
)

func svc(ns, name string, ports ...corev1.ServicePort) *corev1.Service {
	if len(ports) == 0 {
		ports = []corev1.ServicePort{{Port: 80, Protocol: corev1.ProtocolTCP}}
	}
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Spec:       corev1.ServiceSpec{Ports: ports},
	}
}

// The first live run adopted eight candidates on a real cluster, five of them
// kube-prometheus-stack scrape targets that do not serve PromQL. The release
// name prefixes those Services, so a substring match on "prometheus" hits all
// of them. Every name here was observed on inno-shared-eks.
func TestScrapeTargetsAreNotMistakenForPrometheus(t *testing.T) {
	notCandidates := []string{
		"kube-prometheus-stack-coredns",
		"kube-prometheus-stack-kube-proxy",
		"kube-prometheus-stack-kube-etcd",
		"kube-prometheus-stack-kube-scheduler",
		"kube-prometheus-stack-kube-controller-manager",
		"kube-prometheus-stack-prometheus-node-exporter",
		"kube-prometheus-stack-kube-state-metrics",
		"prometheus-json-exporter",
		"lgtm-distributed-loki-gateway",
		"lgtm-distributed-loki-query-frontend",
		"lgtm-distributed-tempo-query-frontend",
		"lgtm-distributed-grafana",
		"lgtm-distributed-mimir-alertmanager",
	}
	for _, name := range notCandidates {
		if c, ok := classifyService(*svc("observability", name)); ok {
			t.Errorf("%s was adopted as %q, but it does not serve PromQL", name, c.why)
		}
	}
}

func TestRealQueryEndpointsAreRecognised(t *testing.T) {
	want := map[string]string{
		"lgtm-distributed-mimir-nginx":          "/prometheus",
		"lgtm-distributed-mimir-query-frontend": "/prometheus",
		"kube-prometheus-stack-prometheus":      "",
		"prometheus":                            "",
		"thanos-query":                          "",
	}
	for name, prefix := range want {
		c, ok := classifyService(*svc("observability", name))
		if !ok {
			t.Errorf("%s was not recognised as a query endpoint", name)
			continue
		}
		if c.prefix != prefix {
			t.Errorf("%s: prefix = %q, want %q", name, c.prefix, prefix)
		}
	}
}

// The gateway must outrank the query-frontend: it injects a default
// X-Scope-OrgID, so multi-tenant Mimir answers without --tenant.
func TestGatewayOutranksQueryFrontend(t *testing.T) {
	cs := fake.NewSimpleClientset(
		svc("observability", "lgtm-distributed-mimir-query-frontend", corev1.ServicePort{Name: "http", Port: 8080}),
		svc("observability", "lgtm-distributed-loki-gateway"),
		svc("kube-system", "kube-prometheus-stack-coredns", corev1.ServicePort{Name: "http-metrics", Port: 9153}),
		svc("observability", "lgtm-distributed-mimir-nginx", corev1.ServicePort{Name: "http", Port: 80}),
	)

	cfg := config.Default()

	got, seen, err := findCandidates(context.Background(), cs, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if seen == 0 {
		t.Fatal("seen count is 0; the \"no endpoint\" error uses it to distinguish an\n" +
			"empty namespace from one full of services that do not serve PromQL")
	}
	if len(got) != 2 {
		var names []string
		for _, c := range got {
			names = append(names, c.String())
		}
		t.Fatalf("got %d candidates %v, want 2", len(got), names)
	}
	if got[0].service != "lgtm-distributed-mimir-nginx" {
		t.Errorf("first candidate = %s, want the mimir gateway", got[0].service)
	}
}

// gRPC sits alongside HTTP on a Mimir gateway; picking the wrong one fails in
// a way that looks like the endpoint is down.
func TestNamedHTTPPortWinsOverOrdinalPosition(t *testing.T) {
	port, name, ok := servicePort(*svc("observability", "lgtm-distributed-mimir-nginx",
		corev1.ServicePort{Name: "grpc", Port: 9095},
		corev1.ServicePort{Name: "http", Port: 80},
	))
	if !ok || port != 80 || name != "http" {
		t.Errorf("servicePort = %d/%q (%v), want 80/\"http\"", port, name, ok)
	}
}

// The Service port is rarely the container port: lgtm-distributed's gateway
// listens on 8080 behind a Service on 80, and port-forward needs the latter.
func TestEndpointPortResolvesByName(t *testing.T) {
	ports := []corev1.EndpointPort{{Name: "grpc", Port: 9095}, {Name: "http", Port: 8080}}
	got, ok := endpointPort(ports, "http")
	if !ok || got != 8080 {
		t.Errorf("endpointPort = %d (%v), want 8080", got, ok)
	}
}
