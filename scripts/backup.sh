#!/bin/sh
# Consistent backup of the monitoring stack. Runs ON the phone as root:
#   sudo sh /opt/phonehost/scripts/backup.sh [output_dir]
#
# Produces <output_dir>/phonehost-<host>-<timestamp>.tar.gz containing a
# VictoriaMetrics snapshot, an online sqlite copy of grafana.db, Alertmanager
# state and every config file this repo manages.
#
# WARNING: the archive contains secrets (Grafana admin password in
# /etc/conf.d/grafana, Telegram bot token, VictoriaMetrics auth keys).
# Keep it as private as you keep the phone itself.
set -eu

OUT=${1:-/var/tmp/phonehost-backups}
VM_URL=${VM_URL:-http://127.0.0.1:8428}
VM_DATA=/var/lib/victoria-metrics
GRAFANA_DB=/var/lib/grafana/data/grafana.db
AM_DATA=/var/lib/alertmanager/data
STAMP=$(date -u +%Y%m%d-%H%M%S)
HOST=$(hostname)
NAME="phonehost-$HOST-$STAMP"

if [ "$(id -u)" != 0 ]; then
	echo "run as root: sudo sh $0" >&2
	exit 1
fi

log() { printf '\033[1;32m==\033[0m %s\n' "$*"; }

WORK=$(mktemp -d /var/tmp/phonehost-backup.XXXXXX)
SNAPSHOT=""
cleanup() {
	[ -n "$SNAPSHOT" ] && curl -s "$VM_URL/snapshot/delete?authKey=$AUTHKEY&snapshot=$SNAPSHOT" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

install -d "$OUT" "$WORK/$NAME"

# ------------------------------------------------------- VictoriaMetrics
log "VictoriaMetrics snapshot"
AUTHKEY=$(cat /etc/victoria-metrics/snapshot.key 2>/dev/null || echo "")
RESP=$(curl -sS "$VM_URL/snapshot/create?authKey=$AUTHKEY")
SNAPSHOT=$(printf '%s' "$RESP" | sed -n 's/.*"snapshot":"\([^"]*\)".*/\1/p')
if [ -z "$SNAPSHOT" ]; then
	echo "snapshot failed: $RESP" >&2
	exit 1
fi
install -d "$WORK/$NAME/victoria-metrics"
tar -C "$VM_DATA/snapshots/$SNAPSHOT" -cf - . | tar -C "$WORK/$NAME/victoria-metrics" -xf -
curl -s "$VM_URL/snapshot/delete?authKey=$AUTHKEY&snapshot=$SNAPSHOT" >/dev/null
SNAPSHOT=""

# ------------------------------------------------------- Grafana
log "Grafana database"
install -d "$WORK/$NAME/grafana"
if command -v sqlite3 >/dev/null 2>&1; then
	sqlite3 "$GRAFANA_DB" ".backup '$WORK/$NAME/grafana/grafana.db'"
else
	echo "  sqlite3 missing - stopping grafana for a cold copy"
	rc-service grafana stop >/dev/null
	cp "$GRAFANA_DB" "$WORK/$NAME/grafana/grafana.db"
	rc-service grafana start >/dev/null
fi

# ------------------------------------------------------- Alertmanager
log "Alertmanager state"
if [ -d "$AM_DATA" ]; then
	install -d "$WORK/$NAME/alertmanager"
	tar -C "$AM_DATA" -cf - . | tar -C "$WORK/$NAME/alertmanager" -xf -
fi

# ------------------------------------------------------- configs
log "configs"
install -d "$WORK/$NAME/etc"
tar -cf - \
	/etc/conf.d/victoria-metrics /etc/conf.d/vmalert /etc/conf.d/grafana \
	/etc/conf.d/node-exporter /etc/conf.d/alertmanager \
	/etc/init.d/vmalert /etc/victoria-metrics /etc/alertmanager \
	/etc/nftables.d/60_monitoring.nft /etc/profile.d/dev-toolchains.sh 2>/dev/null \
	| tar -C "$WORK/$NAME/etc" --strip-components=1 -xf - || true

# ------------------------------------------------------- manifest
{
	echo "host:      $HOST"
	echo "created:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "kernel:    $(uname -r)"
	echo "os:        $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"
	echo "packages:"
	for p in victoria-metrics victoria-metrics-tools grafana alertmanager prometheus-node-exporter; do
		v=$(apk list -I "$p" 2>/dev/null | head -1 | awk '{print $1}')
		echo "  $v"
	done
	echo "series:    $(curl -s "$VM_URL/api/v1/series/count" | sed -n 's/.*"data":\[\([0-9]*\)\].*/\1/p')"
} > "$WORK/$NAME/manifest.txt"

# ------------------------------------------------------- pack
log "packing"
tar -C "$WORK" -czf "$OUT/$NAME.tar.gz" "$NAME"
chmod 600 "$OUT/$NAME.tar.gz"
# let the user who invoked sudo pull the archive over plain ssh
if [ -n "${SUDO_USER:-}" ]; then
	chown "$SUDO_USER" "$OUT/$NAME.tar.gz"
	chmod 755 "$OUT"
fi
log "wrote $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"

# keep the newest 10 archives
ls -1t "$OUT"/phonehost-*.tar.gz 2>/dev/null | tail -n +11 | while read -r old; do
	echo "   pruning $(basename "$old")"
	rm -f "$old"
done
