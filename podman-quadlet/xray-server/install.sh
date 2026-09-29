#!/bin/sh

set -eu

unit_dir=/etc/containers/systemd

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

build_image() {
    dir=$1
    unit=$2
    image=$(sed -n 's/^[[:space:]]*Image=//p' "$dir/$unit.container" | head -n 1)
    podman build -t "$image" "$dir"
}

build_image "$script_dir/xray-server-main" xray-server-main
build_image "$script_dir/xray-server-warp" xray-server-warp

install -d -m0755 "$unit_dir"
install -m0644 "$script_dir/xray-server.network" "$unit_dir/xray-server.network"

install -d -m0755 "$unit_dir/xray-server-main.container.d"
install -m0644 "$script_dir/xray-server-main/xray-server-main.container" "$unit_dir/xray-server-main.container"
[ -f "$unit_dir/xray-server-main.container.d/10-environment.conf" ] \
    || install -m0644 "$script_dir/xray-server-main/xray-server-main.container.d/10-environment.conf" \
        "$unit_dir/xray-server-main.container.d/10-environment.conf"

install -m0644 "$script_dir/xray-server-warp/xray-server-warp.container" "$unit_dir/xray-server-warp.container"

install -d -m0755 "$unit_dir/xray-server-warp.container.d"
[ -f "$unit_dir/xray-server-warp.container.d/10-environment.conf" ] \
    || install -m0644 "$script_dir/xray-server-warp/xray-server-warp.container.d/10-environment.conf" \
        "$unit_dir/xray-server-warp.container.d/10-environment.conf"
