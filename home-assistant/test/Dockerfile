# The test's machines (scripts/test-home-assistant.sh): Alpine with
# iptables (the home router's NAT) and iproute2 (the home
# machine's default route). The programs (released nfltr and
# nfltr-relay, the example's Go programs) are static linux builds, mounted at /opt/ha.
FROM alpine:3.20
RUN apk add --no-cache iptables iproute2
