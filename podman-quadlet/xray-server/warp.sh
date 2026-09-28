#!/bin/sh
#
# Minimal Cloudflare WARP client for the xray-server image.
#
#   warp.sh ensure     register a WARP account if no state exists yet
#   warp.sh register   force a fresh registration
#   warp.sh outbound   print the Xray wireguard outbound (tag "warp")
#
# The account state lives in $WARP_STATE_DIR so it can be kept in a volume.
# The container environment is assumed to be stable: no extra probing or
# pretty output, failures abort the caller via the non-zero exit status.

set -eu
umask 077

WARP_STATE_DIR="${WARP_STATE_DIR:-/var/lib/warp}"
WARP_STATE_FILE="$WARP_STATE_DIR/warp.json"
WARP_API="https://api.cloudflareclient.com/v0a2158/reg"
WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
# The WARP endpoint is pinned on purpose: always use this host:port and never
# the endpoint returned by the registration API.
WARP_ENDPOINT="engage.cloudflareclient.com:2408"

rand_chars() {
    head -c $(( $1 * 2 )) /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"
}

register() {
    private_key="$(wg genkey)"
    public_key="$(printf '%s' "$private_key" | wg pubkey)"
    install_id="$(rand_chars 22)"
    fcm_token="$install_id:APA91b$(rand_chars 134)"
    tos="$(date -u +%Y-%m-%dT%H:%M:%S).000Z"

    payload="$(jq -n \
        --arg key "$public_key" \
        --arg install_id "$install_id" \
        --arg fcm_token "$fcm_token" \
        --arg tos "$tos" \
        '{key: $key, install_id: $install_id, fcm_token: $fcm_token, tos: $tos, model: "Android", serial_number: $install_id}')"

    response="$(curl -fsS --max-time 30 -X POST "$WARP_API" \
        -H "CF-Client-Version: a-7.21-0721" \
        -H "User-Agent: okhttp/0.7.21" \
        -H "Content-Type: application/json" \
        -d "$payload")"

    client_id="$(printf '%s' "$response" | jq -r '.config.client_id')"
    reserved="[$(printf '%s' "$client_id" | base64 -d | od -An -tu1 \
        | awk '{ for (i = 1; i <= NF; i++) printf "%s%s", (n++ ? "," : ""), $i }')]"

    mkdir -p "$WARP_STATE_DIR"
    printf '%s' "$response" | jq -c \
        --arg private_key "$private_key" \
        --argjson reserved "$reserved" \
        --arg fallback_key "$WARP_PEER_PUBLIC_KEY" \
        --arg endpoint "$WARP_ENDPOINT" \
        '{
            id: .id,
            token: .token,
            private_key: $private_key,
            public_key: (.config.peers[0].public_key // $fallback_key),
            endpoint: $endpoint,
            address_v4: .config.interface.addresses.v4,
            address_v6: .config.interface.addresses.v6,
            reserved: $reserved
        }' > "$WARP_STATE_FILE.tmp"
    mv "$WARP_STATE_FILE.tmp" "$WARP_STATE_FILE"
}

outbound() {
    jq -c --arg endpoint "$WARP_ENDPOINT" '{
        protocol: "wireguard",
        tag: "warp",
        settings: {
            secretKey: .private_key,
            address: [.address_v4 + "/32", .address_v6 + "/128"],
            peers: [{
                publicKey: .public_key,
                allowedIPs: ["0.0.0.0/0", "::/0"],
                endpoint: $endpoint
            }],
            noKernelTun: true,
            mtu: 1280,
            reserved: .reserved
        }
    }' "$WARP_STATE_FILE"
}

case "${1:-}" in
    ensure)
        [ -f "$WARP_STATE_FILE" ] || register
        ;;
    register)
        register
        ;;
    outbound)
        outbound
        ;;
    *)
        echo "usage: warp.sh {ensure|register|outbound}" >&2
        exit 2
        ;;
esac
