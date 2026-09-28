# xray-server

Xray VLESS + REALITY server as a Podman Quadlet unit.

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

## Update

```sh
podman-quadlet/xray-server/install.sh
systemctl daemon-reload
systemctl restart xray-server.service
```
