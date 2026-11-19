# The example's one image (scripts/test-gpu-box.sh): Alpine with
# iptables (the home router's NAT and delay), iproute2 (the home
# machine's default route, tc) and script(1) (util-linux-misc: the owner types
# the organisation root's passphrase, scripts/lib/org.sh). The programs (released nfltr and
# nfltr-relay, the example's Go programs) are static linux builds, mounted at /opt/gb.
FROM alpine:3.20
RUN apk add --no-cache iptables iproute2 util-linux-misc
