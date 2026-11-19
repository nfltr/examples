# Each example's end-to-end test runs against the released nfltr and
# nfltr-relay (install.sh; NFLTR_VERSION=vX.Y.Z pins one). Needs docker,
# openssl, python3 and Go.
EXAMPLES := device-gateway dotnet-fleet gpu-box home-assistant pihole reverse-proxy

.PHONY: check build $(EXAMPLES)
check: build $(EXAMPLES)

build:
	go vet ./...
	go build ./...

$(EXAMPLES):
	./scripts/test-$@.sh
