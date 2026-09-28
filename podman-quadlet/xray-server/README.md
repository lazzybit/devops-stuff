# xray-server

Xray VLESS + REALITY server as a Podman Quadlet unit, with a Cloudflare WARP
outbound.

## Files

| File | Purpose |
| --- | --- |
| `Containerfile` | Image with a pinned Xray release. |
| `entrypoint.sh` | Renders the config and runs Xray. |
| `warp.sh` | Registers a Cloudflare WARP account and emits the WireGuard outbound. |
| `xray-server.container` | Quadlet unit. |
| `xray-server.container.d/10-environment.conf` | Configuration drop-in template. |
| `xray-server-warp.volume` | Quadlet volume holding the WARP account state. |
| `install.sh` | Installer. |

## Requirements

- Podman >= 5.0 with Quadlet (for drop-in support), and systemd
- Root, the unit publishes port 443
- Network access during the image build

## Install

```sh
podman-quadlet/xray-server/install.sh
```

Fill in the installed drop-in with `XRAY_UUID` and `XRAY_REALITY_SERVER_NAME`,
create the `xray-server-private-key` secret (see Key pair), reload systemd and
then start the service:

```sh
systemctl daemon-reload
systemctl start xray-server.service
journalctl -u xray-server.service -f
```

`XRAY_UUID` and `XRAY_REALITY_SERVER_NAME` are required. `XRAY_LOG_LEVEL` is
optional: leave it unset to disable logging, or set it to `debug`, `info`,
`warning` or `error`. Do not set `XRAY_PRIVATE_KEY` in the drop-in; it comes from
the Podman secret.

## Key pair

```sh
podman run --rm --entrypoint /usr/local/bin/xray \
    localhost/xray-server:26.3.27 x25519 \
    | awk '/^Private/ { printf "%s", $2 }' \
    | podman secret create xray-server-private-key -
```

Public key for the client, derived from the secret:

```sh
podman run --rm --secret xray-server-private-key,type=env,target=XRAY_PRIVATE_KEY \
    --entrypoint sh localhost/xray-server:26.3.27 \
    -c 'xray x25519 -i "$XRAY_PRIVATE_KEY"' \
    | awk '/PublicKey/ { print $NF }'
```

## Client

| Setting | Value |
| --- | --- |
| Protocol | VLESS |
| Address / Port | server address, `443` |
| UUID | `XRAY_UUID` |
| Flow | `xtls-rprx-vision` |
| Transport | `raw` (TCP) |
| Security | REALITY |
| SNI / serverName | `XRAY_REALITY_SERVER_NAME` |
| Public key | `Password (PublicKey)` |
| Short ID | empty |
| Fingerprint | `chrome` |

## Cloudflare WARP

A WireGuard outbound with tag `warp` is always added. Account state lives in the
`xray-server-warp` volume. To reset it, stop the service and remove the volume:

```sh
systemctl stop xray-server.service
podman volume rm xray-server-warp
systemctl start xray-server.service
```

## Update

```sh
podman-quadlet/xray-server/install.sh
systemctl daemon-reload
systemctl restart xray-server.service
```
