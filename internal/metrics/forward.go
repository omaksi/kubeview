package metrics

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

// forwardReadyTimeout bounds how long we wait for a forward to come up. The
// handshake is API server plus kubelet, so it is fast when it works at all;
// waiting longer mostly delays the fallback to the next candidate.
const forwardReadyTimeout = 12 * time.Second

// forwarder is a live port-forward to one pod. It must be closed when the
// program exits, or the goroutine and the local socket leak.
type forwarder struct {
	local  int
	stop   chan struct{}
	closed bool
}

func (f *forwarder) Close() {
	if f == nil || f.closed {
		return
	}
	f.closed = true
	close(f.stop)
}

// startForward opens a port-forward to a ready pod behind a Service.
//
// Why not the API server's service proxy, which needs no local port at all:
// on EKS the control plane cannot open connections into the pod network, so
// /proxy hangs indefinitely for any Service that has real endpoints — verified
// against inno-shared-eks, where `kubectl get --raw .../proxy/...` returned
// nothing for 45s while `get services/proxy` was allowed. Port-forward goes
// API server -> kubelet -> pod, which is the path kubectl itself uses and the
// one that is actually routable. Do not "simplify" this back to the proxy.
func startForward(ctx context.Context, cs kubernetes.Interface, restCfg *rest.Config, c candidate) (*forwarder, error) {
	pod, targetPort, err := readyEndpoint(ctx, cs, c)
	if err != nil {
		return nil, err
	}

	roundTripper, upgrader, err := spdy.RoundTripperFor(restCfg)
	if err != nil {
		return nil, fmt.Errorf("build spdy transport: %w", err)
	}

	u, err := url.Parse(restCfg.Host)
	if err != nil {
		return nil, fmt.Errorf("parse API server URL %q: %w", restCfg.Host, err)
	}
	u.Path = fmt.Sprintf("/api/v1/namespaces/%s/pods/%s/portforward", c.namespace, pod)

	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: roundTripper}, http.MethodPost, u)

	stop := make(chan struct{})
	ready := make(chan struct{})

	// Local port 0 lets the OS choose, so two instances of the tool never
	// collide and nothing has to be reserved in advance.
	fw, err := portforward.New(dialer,
		[]string{fmt.Sprintf("0:%d", targetPort)}, stop, ready, io.Discard, io.Discard)
	if err != nil {
		close(stop)
		return nil, fmt.Errorf("port-forward to %s/%s: %w", c.namespace, pod, err)
	}

	errCh := make(chan error, 1)
	go func() { errCh <- fw.ForwardPorts() }()

	select {
	case <-ready:
	case err := <-errCh:
		close(stop)
		return nil, fmt.Errorf("port-forward to %s/%s: %w", c.namespace, pod, err)
	case <-time.After(forwardReadyTimeout):
		close(stop)
		return nil, fmt.Errorf("port-forward to %s/%s did not become ready", c.namespace, pod)
	case <-ctx.Done():
		close(stop)
		return nil, ctx.Err()
	}

	ports, err := fw.GetPorts()
	if err != nil || len(ports) == 0 {
		close(stop)
		return nil, fmt.Errorf("port-forward to %s/%s reported no local port", c.namespace, pod)
	}
	return &forwarder{local: int(ports[0].Local), stop: stop}, nil
}

// readyEndpoint resolves a Service to a ready pod and the container port.
//
// Port-forward targets a pod, not a Service, and the container port is rarely
// the Service port — lgtm-distributed's mimir gateway listens on 8080 behind a
// Service on 80. The Endpoints object already carries the resolved number, so
// there is no need to interpret targetPort ourselves.
func readyEndpoint(ctx context.Context, cs kubernetes.Interface, c candidate) (string, int32, error) {
	ep, err := cs.CoreV1().Endpoints(c.namespace).Get(ctx, c.service, metav1.GetOptions{})
	if err != nil {
		return "", 0, fmt.Errorf("endpoints for %s/%s: %w", c.namespace, c.service, err)
	}

	for _, sub := range ep.Subsets {
		port, ok := endpointPort(sub.Ports, c.portName)
		if !ok {
			continue
		}
		for _, addr := range sub.Addresses {
			if addr.TargetRef != nil && addr.TargetRef.Kind == "Pod" {
				return addr.TargetRef.Name, port, nil
			}
		}
	}
	return "", 0, fmt.Errorf("%s/%s has no ready pod endpoints", c.namespace, c.service)
}
