# ntfy

ntfy push notification server as a Podman Quadlet unit.

## Requirements

- Podman >= 5.0 with Quadlet, and systemd
- Root
- Network access during the image pull

## Install

```sh
podman-quadlet/ntfy/install.sh
```

Generate a bcrypt password hash:

```sh
podman run --rm -it docker.io/binwiederhier/ntfy:latest user hash
```

Edit the installed drop-in and set `NTFY_BASE_URL` and `NTFY_AUTH_USERS`:

```sh
$EDITOR /etc/containers/systemd/ntfy.container.d/10-environment.conf
```

`NTFY_AUTH_USERS` holds one or more `<user>:<bcrypt-hash>:<role>` entries,
comma-separated. Enter the `$` characters in the hash literally.

```sh
systemctl daemon-reload
systemctl start ntfy.service
journalctl -u ntfy.service -f
```

## Network

Nothing is published to the host. To reach the server from another container
(including Cloudflare Tunnel), add a drop-in selecting a shared network:

```sh
$EDITOR /etc/containers/systemd/ntfy.container.d/20-network.conf
```

```ini
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
