#!/bin/sh
#
# Render the Xray VLESS + REALITY server config from XRAY_* variables and
# start Xray.
#
# Required:
#   XRAY_UUID                  VLESS UUID
#   XRAY_REALITY_SERVER_NAME   REALITY TLS server name (domain)
#   XRAY_PRIVATE_KEY           REALITY x25519 private key (normally a Podman secret)
#
# Optional:
#   XRAY_LOG_LEVEL             debug | info | warning | error (unset: none)
#   WARP_SOCKS_SERVER          host:port of the WARP egress proxy
#                              (default: xray-server-warp:1080)
#
# Traffic matched by the routing rules below is sent to the WARP egress proxy
# over SOCKS; everything else uses the "direct" outbound. The proxy runs in the
# separate xray-server-warp container, so a WARP restart never interrupts the
# main server or its direct connections.

set -eu
umask 077

fail() {
    echo "xray: $*" >&2
    exit 1
}

require_env() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || fail "required environment variable $1 is not set"
}

require_env XRAY_UUID
require_env XRAY_REALITY_SERVER_NAME
require_env XRAY_PRIVATE_KEY

log_level="${XRAY_LOG_LEVEL:-none}"
case "$log_level" in
    debug | info | warning | error | none) ;;
    *) fail "XRAY_LOG_LEVEL must be one of: debug, info, warning, error, none" ;;
esac

warp_socks_server="${WARP_SOCKS_SERVER:-xray-server-warp:1080}"
case "$warp_socks_server" in
    *:*) ;;
    *) fail "WARP_SOCKS_SERVER must be host:port" ;;
esac
warp_socks_host="${warp_socks_server%:*}"
warp_socks_port="${warp_socks_server##*:}"
[ -n "$warp_socks_host" ] || fail "WARP_SOCKS_SERVER host is empty"
case "$warp_socks_port" in
    '' | *[!0-9]*) fail "WARP_SOCKS_SERVER port must be numeric" ;;
esac
[ "$warp_socks_port" -ge 1 ] && [ "$warp_socks_port" -le 65535 ] \
    || fail "WARP_SOCKS_SERVER port must be between 1 and 65535"

config=/run/xray/config.json

install -d -m0700 "$(dirname "$config")"

jq -n \
    --arg uuid "$XRAY_UUID" \
    --arg server_name "$XRAY_REALITY_SERVER_NAME" \
    --arg private_key "$XRAY_PRIVATE_KEY" \
    --arg log_level "$log_level" \
    --arg warp_socks_host "$warp_socks_host" \
    --argjson warp_socks_port "$warp_socks_port" \
    '{
        log: { loglevel: $log_level },
        routing: {
            domainStrategy: "IPIfNonMatch",
            rules: [
                { type: "field", domain: ["geosite:reddit"], outboundTag: "warp" },
                { type: "field", ip: ["geoip:cn"], outboundTag: "warp" },
                { type: "field", domain: ["geosite:cn"], outboundTag: "warp" },
                { type: "field", protocol: ["bittorrent"], outboundTag: "block" }
            ]
        },
        inbounds: [
            {
                listen: "0.0.0.0",
                port: 443,
                protocol: "vless",
                settings: {
                    clients: [
                        { id: $uuid, flow: "xtls-rprx-vision" }
                    ],
                    decryption: "none"
                },
                streamSettings: {
                    network: "raw",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        target: ($server_name + ":443"),
                        xver: 0,
                        serverNames: [$server_name],
                        privateKey: $private_key,
                        shortIds: [""]
                    }
                },
                sniffing: {
                    enabled: true,
                    destOverride: ["http", "tls", "quic"],
                    routeOnly: true
                }
            }
        ],
        outbounds: [
            { protocol: "freedom", tag: "direct" },
            { protocol: "blackhole", tag: "block" },
            {
                protocol: "socks",
                tag: "warp",
                settings: {
                    servers: [
                        { address: $warp_socks_host, port: $warp_socks_port }
                    ]
                }
            }
        ]
    }' > "$config"

exec xray run -config "$config"
