# cloudflare-tunnel

Cloudflare Tunnel as a Podman Quadlet unit.

## Requirements

- Podman >= 5.0 with Quadlet, and systemd
- Root
- A Cloudflare Zero Trust tunnel token

## Install

```sh
podman-quadlet/cloudflare-tunnel/install.sh
```

```sh
podman secret create cloudflare-tunnel-token -
```

```sh
systemctl daemon-reload
systemctl start cloudflare-tunnel.service
```

## Auto-update

```sh
systemctl enable --now podman-auto-update.timer
```

## Token rotation

```sh
podman secret create --replace cloudflare-tunnel-token -
```

```sh
systemctl restart cloudflare-tunnel.service
```

## Update

```sh
podman-quadlet/cloudflare-tunnel/install.sh
systemctl daemon-reload
systemctl restart cloudflare-tunnel.service
```
