#!/bin/sh
#
# Render an Xray VLESS + REALITY server config from XRAY_* variables and
# start Xray.
#
# Required:
#   XRAY_UUID                  VLESS UUID
#   XRAY_REALITY_SERVER_NAME   REALITY TLS server name (domain)
#   XRAY_PRIVATE_KEY           REALITY x25519 private key (normally a Podman secret)
#
# Optional:
#   XRAY_LOG_LEVEL             debug | info | warning | error (unset: none)

# A Cloudflare WARP wireguard outbound (tag "warp") is always added, using a
# fresh account registered on every start (state under /run/warp).

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

config=/run/xray/config.json

install -d -m0700 "$(dirname "$config")"

/usr/local/bin/warp.sh register
warp_outbound="$(/usr/local/bin/warp.sh outbound)"

jq -n \
    --arg uuid "$XRAY_UUID" \
    --arg server_name "$XRAY_REALITY_SERVER_NAME" \
    --arg private_key "$XRAY_PRIVATE_KEY" \
    --arg log_level "$log_level" \
    --argjson warp_outbound "$warp_outbound" \
    '{
        log: { loglevel: $log_level },
        dns: {
            servers: [
                "quic+local://dns.quad9.net",
                "https+local://doh.dns.sb/dns-query"
            ],
            queryStrategy: "UseIP"
        },
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
            $warp_outbound
        ]
    }' > "$config"

exec xray run -config "$config"
