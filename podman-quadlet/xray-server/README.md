# xray-server

Xray VLESS + REALITY server as a Podman Quadlet unit.

## Files

| File | Purpose |
| --- | --- |
| `Containerfile` | Image with a pinned Xray release. |
| `entrypoint.sh` | Renders the config and runs Xray. |
| `warp.sh` | Registers a Cloudflare WARP account and emits the WireGuard outbound. |
| `xray-server.container` | Quadlet unit. |
| `xray-server-warp.volume` | Quadlet volume holding the WARP account state. |

## Requirements

- Podman >= 4.6 with Quadlet, and systemd
- Network access during the image build

## Build

```sh
cd podman-quadlet/xray-server
podman build -t localhost/xray-server:26.3.27 .
```

To change the Xray version, update `XRAY_VERSION` and both SHA-256 arguments
in `Containerfile`.

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

## Install

Set `XRAY_UUID` and `XRAY_REALITY_SERVER_NAME` in
`podman-quadlet/xray-server/xray-server.container`, then:

```sh
sudo install -m0644 podman-quadlet/xray-server/xray-server-warp.volume \
    /etc/containers/systemd/xray-server-warp.volume
sudo install -m0644 podman-quadlet/xray-server/xray-server.container \
    /etc/containers/systemd/xray-server.container
sudo systemctl daemon-reload
sudo systemctl start xray-server.service
journalctl -u xray-server.service -f
```

The unit starts on boot. For rootless use, install into
`~/.config/containers/systemd/` and use `systemctl --user`.

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

## Environment variables

| Variable | Description |
| --- | --- |
| `XRAY_UUID` | VLESS UUID. |
| `XRAY_REALITY_SERVER_NAME` | REALITY TLS server name (domain). |
| `XRAY_PRIVATE_KEY` | REALITY x25519 private key. |

`XRAY_UUID`, `XRAY_REALITY_SERVER_NAME` and `XRAY_PRIVATE_KEY` are required.

## Cloudflare WARP

A WireGuard outbound with tag `warp` is always added. Account state lives in
the `xray-server-warp` volume.

To reset it, stop the service and remove the volume:

```sh
sudo systemctl stop xray-server.service
podman volume rm xray-server-warp
sudo systemctl start xray-server.service
```

## Update

```sh
cd podman-quadlet/xray-server
podman build -t localhost/xray-server:<version> .
sudo systemctl daemon-reload   # .container changes only
sudo systemctl restart xray-server.service
```

Update `Image=` in `xray-server.container` when the tag changes.
