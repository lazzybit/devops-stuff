# xray-server

Xray VLESS + REALITY server as Podman Quadlet units.

Two containers share the `xray-server` network:

- `xray-server-main` — the public server (port 443). Reddit and CN traffic goes
  through WARP, everything else directly.
- `xray-server-warp` — the WARP SOCKS egress. It registers a new WARP account on
  every start and restarts itself when WARP stops working.

## Requirements

- Podman >= 5.0 with Quadlet, and systemd
- Root, the main unit publishes port 443
- Network access during the image build

## Install

```sh
podman-quadlet/xray-server/install.sh
```

Fill in the installed `xray-server-main` drop-in with `XRAY_UUID` and
`XRAY_REALITY_SERVER_NAME`, create the `xray-server-private-key` secret (see Key
pair), reload systemd and start:

```sh
systemctl daemon-reload
systemctl start xray-server-warp.service xray-server-main.service
journalctl -u xray-server-main.service -f
```

`XRAY_LOG_LEVEL` is optional (`debug`, `info`, `warning`, `error`); both units
honor it through their drop-ins. Do not set `XRAY_PRIVATE_KEY` in the drop-in;
it comes from the Podman secret.

## Key pair

```sh
podman run --rm --entrypoint /usr/local/bin/xray \
    localhost/xray-server-main:26.3.27 x25519 \
    | awk '/^Private/ { printf "%s", $2 }' \
    | podman secret create xray-server-private-key -
```

Public key for the client:

```sh
podman run --rm --secret xray-server-private-key,type=env,target=XRAY_PRIVATE_KEY \
    --entrypoint sh localhost/xray-server-main:26.3.27 \
    -c 'xray x25519 -i "$XRAY_PRIVATE_KEY"' \
    | awk '/PublicKey/ { print $NF }'
```

## Update

```sh
podman-quadlet/xray-server/install.sh
systemctl daemon-reload
systemctl restart xray-server-warp.service xray-server-main.service
```
