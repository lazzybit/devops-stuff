# xray-server

Xray VLESS + REALITY server as Podman Quadlet units.

The deployment is split into two containers on a shared `xray-server` network:

- `xray-server-main` — the public VLESS + REALITY server. Destination traffic
  matched by the routing rules (Reddit and CN) leaves through a SOCKS outbound
  pointing at the WARP container; everything else goes out directly.
- `xray-server-warp` — a Cloudflare WARP egress proxy on the internal network.

Keeping WARP in its own container means a WARP restart never interrupts the main
server or its direct connections. Only the main server publishes a port (443).

## Requirements

- Podman >= 5.0 with Quadlet (for drop-in support), and systemd
- Root, the main unit publishes port 443
- Network access during the image build

## Install

```sh
podman-quadlet/xray-server/install.sh
```

Fill in the installed drop-in with `XRAY_UUID` and `XRAY_REALITY_SERVER_NAME`,
create the `xray-server-private-key` secret (see Key pair), reload systemd and
then start the services:

```sh
systemctl daemon-reload
systemctl start xray-server-warp.service xray-server-main.service
journalctl -u xray-server-main.service -f
```

`XRAY_UUID` and `XRAY_REALITY_SERVER_NAME` are required. `XRAY_LOG_LEVEL` is
optional: leave it unset to disable logging, or set it to `debug`, `info`,
`warning` or `error`. Do not set `XRAY_PRIVATE_KEY` in the drop-in; it comes from
the Podman secret.

`xray-server-main.service` wants `xray-server-warp.service`, but a WARP outage
does not stop the main service: only WARP traffic fails until the proxy is
healthy again.

## Key pair

```sh
podman run --rm --entrypoint /usr/local/bin/xray \
    localhost/xray-server-main:26.3.27 x25519 \
    | awk '/^Private/ { printf "%s", $2 }' \
    | podman secret create xray-server-private-key -
```

Public key for the client, derived from the secret:

```sh
podman run --rm --secret xray-server-private-key,type=env,target=XRAY_PRIVATE_KEY \
    --entrypoint sh localhost/xray-server-main:26.3.27 \
    -c 'xray x25519 -i "$XRAY_PRIVATE_KEY"' \
    | awk '/PublicKey/ { print $NF }'
```

## WARP supervision

`xray-server-warp` registers a new Cloudflare WARP account on every start and
restarts itself when WARP stops working, so a bad or invalidated account is
replaced automatically.

The container probes WARP every 15s (10s timeout, 2 retries); two consecutive
failures restart it after `RestartSec=5s`. It also probes once at startup so a
fresh but unusable account is replaced right away.

Restarting WARP only drops its in-flight WARP connections; the main server and
its direct connections keep running. The timing can be overridden with a
Quadlet drop-in in `/etc/containers/systemd/xray-server-warp.container.d/`.

## Update

```sh
podman-quadlet/xray-server/install.sh
systemctl daemon-reload
systemctl restart xray-server-warp.service xray-server-main.service
```
