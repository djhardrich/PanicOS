#!/bin/sh
# Generate dropbear host keys at first boot. Self-disabling via marker on
# the storage partition. Keys live in /etc/dropbear/ (on the overlay), so
# they persist normally and are wiped only when the user resets the
# overlay — exactly the right granularity (per-device, per-flavor).

set -eu

MARKER=/storage/.panicos-sshkeys-done
[ -f "$MARKER" ] && exit 0

mkdir -p /etc/dropbear

# Dropbear ships dropbearkey for host-key generation. RSA + Ed25519 are
# the two modern algorithms; ECDSA is intentionally skipped (Ed25519 is
# its successor, smaller and faster).
for type in rsa ed25519; do
    keyfile="/etc/dropbear/dropbear_${type}_host_key"
    if [ ! -s "$keyfile" ]; then
        echo ">>> panicos-sshkeys: generating $type host key"
        dropbearkey -t "$type" -f "$keyfile" >/dev/null
    fi
done

touch "$MARKER"
echo ">>> panicos-sshkeys: done"
