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

- Podman >= 5.0 with Quadlet (for drop-in support), and systemd
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

The Quadlet unit ships no default values. Install the units, then set the
required variables in a Quadlet drop-in over the unit:

```sh
sudo install -m0644 podman-quadlet/xray-server/xray-server-warp.volume \
    /etc/containers/systemd/xray-server-warp.volume
sudo install -m0644 podman-quadlet/xray-server/xray-server.container \
    /etc/containers/systemd/xray-server.container

sudo install -d -m0755 /etc/containers/systemd/xray-server.container.d
sudo tee /etc/containers/systemd/xray-server.container.d/10-environment.conf >/dev/null <<'EOF'
[Container]
Environment=XRAY_UUID=<uuid>
Environment=XRAY_REALITY_SERVER_NAME=<domain>
EOF

sudo systemctl daemon-reload
sudo systemctl start xray-server.service
journalctl -u xray-server.service -f
```

Replace the values in the drop-in with your own. `XRAY_UUID` and
`XRAY_REALITY_SERVER_NAME` are required. `XRAY_LOG_LEVEL` is optional: leave it
unset to disable logging, or add an `Environment=XRAY_LOG_LEVEL=...` line to pick
a level.

Do not add `XRAY_PRIVATE_KEY` here: it is injected from the Podman secret set up
above.

The unit starts on boot. For rootless use, install into
`~/.config/containers/systemd/`, create the drop-in under
`~/.config/containers/systemd/xray-server.container.d/` and use
`systemctl --user`.

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
| `XRAY_LOG_LEVEL` | Error log level: `debug`, `info`, `warning` or `error`; leave unset to disable logging. |

`XRAY_UUID`, `XRAY_REALITY_SERVER_NAME` and `XRAY_PRIVATE_KEY` are required.
The unit sets none of them; provide the first two through a Quadlet drop-in
(see Install) and the private key through the Podman secret.

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
