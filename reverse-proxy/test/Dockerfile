# The test's machines (scripts/test-reverse-proxy.sh): Alpine with
# iptables (the home router's NAT and filter) and iproute2
# (the home server's default route, the router's delay). The programs are
# the released static linux builds, mounted at /opt/rp.
FROM alpine:3.20
RUN apk add --no-cache iptables iproute2
