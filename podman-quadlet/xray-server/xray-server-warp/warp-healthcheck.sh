#!/bin/sh
#
# Probe the Cloudflare WARP outbound of the xray-server-warp container.
#
# The container's only outbound is the "warp" wireguard outbound and its SOCKS
# listener accepts anything that reaches it, so probing the listener exercises
# the real egress path. The Cloudflare trace endpoint answers with "warp=on"
# (or "warp=plus") only when the request actually egresses through WARP, so
# this detects a dead, expired or unusable WARP account regardless of cause.
#
# Exit status 0 means WARP is healthy. The entrypoint also runs this script at
# start to fail fast on a fresh but unusable account; later, a non-zero status
# makes the container unhealthy, which the Quadlet unit turns into a kill and,
# via systemd, a restart that registers a new WARP account.

set -eu

url="https://www.cloudflare.com/cdn-cgi/trace"

# --noproxy "" ignores any no_proxy/proxy environment that could otherwise
# bypass the SOCKS proxy and falsely report direct connectivity as healthy.
# Capture the body explicitly so a curl failure is never swallowed by the
# grep pipeline below.
body="$(curl -fsS --noproxy "" \
    --socks5-hostname 127.0.0.1:1080 \
    --connect-timeout 3 \
    --max-time 8 \
    "$url")" || exit 1

printf '%s\n' "$body" | grep -qE '^warp=(on|plus)$'
