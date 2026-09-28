#!/bin/sh
#
# Install the ntfy Quadlet units (rootful Podman host).
# Existing configuration drop-ins are kept.

set -eu

unit_name=ntfy
unit_dir=/etc/containers/systemd

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=$(sed -n 's/^[[:space:]]*Image=//p' "$script_dir/$unit_name.container" | head -n 1)

podman pull "$image"

install -d -m0755 "$unit_dir/$unit_name.container.d"
install -m0644 "$script_dir/$unit_name.container" "$unit_dir/$unit_name.container"
[ -f "$unit_dir/$unit_name.container.d/10-environment.conf" ] \
    || install -m0600 "$script_dir/$unit_name.container.d/10-environment.conf" \
        "$unit_dir/$unit_name.container.d/10-environment.conf"
