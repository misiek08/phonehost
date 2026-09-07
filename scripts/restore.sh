#!/bin/sh
# Restore a backup produced by backup.sh. Runs ON the phone as root:
#   sudo sh /opt/phonehost/scripts/restore.sh /var/tmp/phonehost-note9pro-<stamp>.tar.gz [--configs]
#
# Without --configs only the data is restored (metrics, Grafana database,
# Alertmanager state); config files stay as they are, which is what you want
# when rolling data back onto a host that setup.sh already configured.
set -eu

ARCHIVE=${1:-}
WITH_CONFIGS=0
[ "${2:-}" = "--configs" ] && WITH_CONFIGS=1

VM_DATA=/var/lib/victoria-metrics
GRAFANA_DB=/var/lib/grafana/data/grafana.db
AM_DATA=/var/lib/alertmanager/data

if [ "$(id -u)" != 0 ]; then
	echo "run as root: sudo sh $0 <archive.tar.gz> [--configs]" >&2
	exit 1
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
	echo "usage: $0 <archive.tar.gz> [--configs]" >&2
	exit 1
fi

log() { printf '\033[1;32m==\033[0m %s\n' "$*"; }

WORK=$(mktemp -d /var/tmp/phonehost-restore.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM

log "unpacking"
tar -C "$WORK" -xzf "$ARCHIVE"
ROOT=$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -f "$ROOT/manifest.txt" ] && cat "$ROOT/manifest.txt"

echo
echo "This replaces the metrics database, the Grafana database and Alertmanager state"
echo "on $(hostname). Current data will be gone."
[ "$WITH_CONFIGS" = 1 ] && echo "Config files under /etc will also be overwritten."
printf 'Continue? [y/N] '
read -r ans
case "$ans" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac

log "stopping services"
for s in grafana vmalert victoria-metrics alertmanager; do
	rc-service "$s" stop >/dev/null 2>&1 || true
done

if [ "$WITH_CONFIGS" = 1 ] && [ -d "$ROOT/etc" ]; then
	log "configs"
	tar -C "$ROOT/etc" -cf - . | tar -C /etc -xf -
	nft -c -f /etc/nftables.nft && rc-service nftables restart >/dev/null
fi

log "VictoriaMetrics data"
if [ -d "$ROOT/victoria-metrics" ]; then
	rm -rf "$VM_DATA".old
	[ -d "$VM_DATA" ] && mv "$VM_DATA" "$VM_DATA".old
	install -d -o victoriametrics -g victoriametrics -m 755 "$VM_DATA"
	tar -C "$ROOT/victoria-metrics" -cf - . | tar -C "$VM_DATA" -xf -
	chown -R victoriametrics:victoriametrics "$VM_DATA"
	echo "   previous data kept at $VM_DATA.old - remove it when you are happy"
fi

log "Grafana database"
if [ -f "$ROOT/grafana/grafana.db" ]; then
	install -d -o grafana -g grafana -m 755 "$(dirname "$GRAFANA_DB")"
	install -o grafana -g grafana -m 640 "$ROOT/grafana/grafana.db" "$GRAFANA_DB"
fi

log "Alertmanager state"
if [ -d "$ROOT/alertmanager" ]; then
	install -d -o prometheus -g prometheus -m 755 "$AM_DATA"
	tar -C "$ROOT/alertmanager" -cf - . | tar -C "$AM_DATA" -xf -
	chown -R prometheus:prometheus "$AM_DATA"
fi

log "starting services"
for s in victoria-metrics node-exporter alertmanager vmalert grafana; do
	rc-service "$s" start >/dev/null 2>&1 || rc-service "$s" restart
done

log "done"
