# The example's one image (scripts/test-pihole.sh): Alpine with
# iptables (the home router's NAT and filter, the box's inbound drop),
# iproute2 (routes, tc), curl (the admin page) and script(1)
# (util-linux-misc: the owner types the organisation root's passphrase,
# scripts/lib/org.sh). The programs (released nfltr and nfltr-relay, the
# example's Go programs) are static linux builds, mounted at /opt/ph.
FROM alpine:3.20
RUN apk add --no-cache iptables iproute2 curl util-linux-misc
