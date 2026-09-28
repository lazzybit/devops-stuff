# ntfy

ntfy push notification server as a Podman Quadlet unit.

## Requirements

- Podman >= 5.0 with Quadlet (for drop-in support), and systemd
- Root
- Network access during the image pull

## Install

```sh
podman-quadlet/ntfy/install.sh
```

Fill in the installed drop-in with `NTFY_BASE_URL` and `NTFY_AUTH_USERS`,
reload systemd and then start the service:

```sh
systemctl daemon-reload
systemctl start ntfy.service
journalctl -u ntfy.service -f
```

`NTFY_BASE_URL` is the externally visible base URL. `NTFY_AUTH_USERS` holds one
or more `<user>:<bcrypt-hash>:<role>` entries, comma-separated; enter the `$`
characters in the hash literally.

## Password hash

```sh
podman run --rm -it docker.io/binwiederhier/ntfy:latest user hash
```

## Network

Nothing is published to the host. To reach the server from another container
(including Cloudflare Tunnel), add a drop-in selecting a shared network:

```ini
# /etc/containers/systemd/ntfy.container.d/20-network.conf
[Container]
Network=cloudflare-tunnel.network
```

The origin is then `http://ntfy:80`.

```sh
systemctl daemon-reload
systemctl restart ntfy.service
```

## Auto-update

```sh
systemctl enable --now podman-auto-update.timer
```

## Update

```sh
podman-quadlet/ntfy/install.sh
systemctl daemon-reload
systemctl restart ntfy.service
```

## State

Users, sessions, access tokens and cached messages are recreated on every
container start; nothing survives container recreation.
