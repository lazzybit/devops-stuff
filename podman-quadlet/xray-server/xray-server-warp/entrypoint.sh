#!/bin/sh
#
# Run a minimal Xray SOCKS egress proxy whose only outbound is Cloudflare WARP.
#
# A fresh WARP account is registered on every start (state under /run/warp), so
# a container restart is all that is needed to replace an account Cloudflare has
# invalidated. Once Xray is listening the entrypoint runs a single bounded
# connectivity probe; when the freshly registered account cannot carry traffic
# it exits non-zero, so systemd restarts the container with a new account.
#
# The SOCKS listener binds the container network and stays unpublished; only
# xray-server-main reaches it through the shared xray-server network. Xray
# answers UDP ASSOCIATE with the local IP of the accepted connection, i.e. the
# bridge IP and not loopback, so UDP forwarding works across network
# namespaces.
#
# Shutdown: SIGTERM/SIGINT is forwarded to Xray and the entrypoint does not
# return until Xray has exited and been reaped. A signal that arrives while the
# start probe is running is deferred until curl returns, which is bounded by the
# probe's 8s total timeout.

set -eu
umask 077

fail() {
    echo "warp: $*" >&2
    exit 1
}

log_level="${XRAY_LOG_LEVEL:-none}"
case "$log_level" in
    debug | info | warning | error | none) ;;
    *) fail "XRAY_LOG_LEVEL must be one of: debug, info, warning, error, none" ;;
esac

# Wall-clock budget for Xray to start accepting connections.
LISTEN_DEADLINE=15

config=/run/xray/config.json
xray_pid=
stopping=0

install -d -m0700 "$(dirname "$config")"

/usr/local/bin/warp.sh register
warp_outbound="$(/usr/local/bin/warp.sh outbound)"

jq -n --argjson warp_outbound "$warp_outbound" --arg log_level "$log_level" '{
    log: { loglevel: $log_level },
    inbounds: [
        {
            listen: "0.0.0.0",
            port: 1080,
            protocol: "socks",
            tag: "warp",
            settings: { auth: "noauth", udp: true }
        }
    ],
    outbounds: [ $warp_outbound ]
}' > "$config"

terminate() {
    stopping=1
    if [ -n "$xray_pid" ]; then
        kill "$xray_pid" 2>/dev/null || true
    fi
}

# Stop Xray, then block until it has exited and been reaped.
stop_xray() {
    if [ -n "$xray_pid" ]; then
        kill "$xray_pid" 2>/dev/null || true
        wait "$xray_pid" 2>/dev/null || true
        xray_pid=
    fi
}

trap terminate INT TERM

xray run -config "$config" &
xray_pid=$!

# Wait for Xray to accept connections. This says nothing about WARP, which the
# probe below decides. The wait is bounded by wall-clock time rather than a
# fixed attempt count, because each nc/sleep step can take about a second.
listening=0
started=$(date +%s)
while [ "$stopping" -eq 0 ]; do
    if ! kill -0 "$xray_pid" 2>/dev/null; then
        wait "$xray_pid" || true
        echo "warp: xray exited during startup" >&2
        exit 1
    fi
    if nc -z -w 1 127.0.0.1 1080 2>/dev/null; then
        listening=1
        break
    fi
    [ $(($(date +%s) - started)) -lt "$LISTEN_DEADLINE" ] || break
    sleep 1
done

if [ "$listening" -ne 1 ]; then
    if [ "$stopping" -eq 0 ]; then
        echo "warp: xray did not start listening" >&2
    fi
    stop_xray
    [ "$stopping" -eq 0 ] && exit 1
    exit 0
fi

# One bounded probe of the freshly registered account. A signal arriving here is
# deferred until the probe returns (see the file header).
if ! /usr/local/bin/warp-healthcheck.sh; then
    if [ "$stopping" -eq 0 ]; then
        echo "warp: freshly registered account cannot carry traffic, restarting" >&2
    fi
    stop_xray
    [ "$stopping" -eq 0 ] && exit 1
    exit 0
fi

# Healthy: stay in the foreground until Xray exits or a signal arrives.
status=0
wait "$xray_pid" || status=$?
if [ "$stopping" -eq 1 ]; then
    # The signal interrupted the wait; make sure Xray has actually exited and
    # been reaped before returning.
    stop_xray
    exit 0
fi
exit "$status"
