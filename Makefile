# Each example's end-to-end test runs against the released nfltr and
# nfltr-relay (install.sh; NFLTR_VERSION=vX.Y.Z pins one). Needs docker,
# openssl, python3 and Go.
EXAMPLES := browser-terminal camera-stream device-gateway dotnet-fleet gpu-box home-assistant pihole remote-desktop reverse-proxy shared-database udp-service

.PHONY: check build $(EXAMPLES)
check: build $(EXAMPLES)

build:
	go vet ./...
	go build ./...

$(EXAMPLES):
	./scripts/test-$@.sh
