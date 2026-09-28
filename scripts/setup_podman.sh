#!/bin/sh
#
# set up Podman for the rootful Quadlet units in podman-quadlet/ (Debian only).
#
# podman already depends on netavark, crun and conmon. aardvark-dns is only a
# recommendation of netavark, so install it explicitly; without it containers
# get no DNS on user-defined networks.
#
# Run as root.

set -eu

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "* | *" ubuntu "*) : ;;
    *) echo "unsupported distribution: ${ID:-unknown} (Debian only)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y podman aardvark-dns

[ -x /usr/lib/podman/aardvark-dns ] || [ -x /usr/libexec/podman/aardvark-dns ] \
    || { echo "aardvark-dns helper not found" >&2; exit 1; }
