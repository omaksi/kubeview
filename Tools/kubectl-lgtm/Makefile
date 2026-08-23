BINARY  := kubectl-lgtm
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build test demo lint install clean

build:
	go build -ldflags '$(LDFLAGS)' -o bin/$(BINARY) ./cmd/$(BINARY)

test:
	go test ./...

# Renders the TUI to stdout without a terminal — useful in CI and for reviewing
# layout changes in a diff.
snapshot:
	go test ./internal/tui/ -run TestViewRendersDemoStack -v

demo: build
	./bin/$(BINARY) --demo

lint:
	go vet ./...
	gofmt -l -d .

# Puts the binary on $PATH so `kubectl lgtm` finds it.
install:
	go install -ldflags '$(LDFLAGS)' ./cmd/$(BINARY)

clean:
	rm -rf bin
