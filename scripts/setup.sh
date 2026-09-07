#!/bin/sh
# Idempotent installer for the note9pro monitoring stack.
# Runs ON the phone as root:  sudo sh /opt/phonehost/scripts/setup.sh
#
# Env overrides:
#   LAN_CIDR=192.168.1.0/24        subnet allowed to reach the stack
#   GRAFANA_ADMIN_PASSWORD=...     set/rotate the Grafana admin password
#   PIN=1                          install the exact versions from versions.env
#   SKIP_PKGS=1                    do not touch apk at all
#   WITH_DEV=1                     also install go/dotnet/gcc toolchains
set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SRC/versions.env"
LAN_CIDR=${LAN_CIDR:-192.168.1.0/24}

if [ "$(id -u)" != 0 ]; then
	echo "run as root: sudo sh $0" >&2
	exit 1
fi

log() { printf '\033[1;32m==\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- packages
if [ "${SKIP_PKGS:-0}" != 1 ]; then
	log "packages"
	if [ "${PIN:-0}" = 1 ]; then
		set -- \
			"victoria-metrics=$VICTORIA_METRICS_VER" \
			"victoria-metrics-openrc=$VICTORIA_METRICS_VER" \
			"victoria-metrics-tools=$VICTORIA_METRICS_TOOLS_VER" \
			"grafana=$GRAFANA_VER" "grafana-openrc=$GRAFANA_VER" \
			"alertmanager=$ALERTMANAGER_VER" "alertmanager-openrc=$ALERTMANAGER_VER" \
			"prometheus-node-exporter=$NODE_EXPORTER_VER" \
			"prometheus-node-exporter-openrc=$NODE_EXPORTER_VER"
	else
		set -- victoria-metrics victoria-metrics-openrc victoria-metrics-tools \
			grafana grafana-openrc alertmanager alertmanager-openrc \
			prometheus-node-exporter prometheus-node-exporter-openrc
	fi
	apk add --quiet sqlite curl "$@"

	if [ "${WITH_DEV:-0}" = 1 ]; then
		log "dev toolchains"
		if [ "${PIN:-0}" = 1 ]; then
			apk add --quiet "go=$GO_VER" "dotnet9-sdk=$DOTNET9_SDK_VER" git make htop tmux
		else
			apk add --quiet go dotnet9-sdk git make htop tmux
		fi
	fi
fi

# ---------------------------------------------------------------- dirs
log "directories"
install -d -m 755 /etc/victoria-metrics /etc/victoria-metrics/alerts
install -d -o grafana -g grafana -m 755 \
	/var/lib/grafana /var/lib/grafana/dashboards /var/lib/grafana/provisioning \
	/var/lib/grafana/provisioning/datasources /var/lib/grafana/provisioning/dashboards

# ---------------------------------------------------------------- auth keys
# VictoriaMetrics /snapshot* and /api/v1/admin/tsdb/delete_series are LAN-reachable,
# so they get random keys. backup.sh reads snapshot.key.
for k in snapshot delete; do
	f=/etc/victoria-metrics/$k.key
	if [ ! -s "$f" ]; then
		log "generating $f"
		head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$f"
	fi
	chown root:victoriametrics "$f"
	chmod 640 "$f"
done

# ---------------------------------------------------------------- configs
log "configs"
install -m 644 "$SRC/etc/conf.d/victoria-metrics" /etc/conf.d/victoria-metrics
install -m 644 "$SRC/etc/conf.d/vmalert"          /etc/conf.d/vmalert
install -m 644 "$SRC/etc/conf.d/node-exporter"    /etc/conf.d/node-exporter
install -m 644 "$SRC/etc/conf.d/alertmanager"     /etc/conf.d/alertmanager
install -m 755 "$SRC/etc/init.d/vmalert"          /etc/init.d/vmalert
install -m 644 "$SRC/etc/victoria-metrics/scrape.yml" /etc/victoria-metrics/scrape.yml

# rules: install ours, drop stale ones we no longer ship
for f in "$SRC"/etc/victoria-metrics/alerts/*.yml; do
	install -m 644 "$f" "/etc/victoria-metrics/alerts/$(basename "$f")"
done
for f in /etc/victoria-metrics/alerts/*.yml; do
	[ -e "$SRC/etc/victoria-metrics/alerts/$(basename "$f")" ] || rm -f "$f"
done

# grafana conf.d: keep the existing password unless one is given
GRAFANA_CONF=/etc/conf.d/grafana
if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
	PW=$GRAFANA_ADMIN_PASSWORD
	NEW_PW=1
elif [ -f "$GRAFANA_CONF" ] && grep -q 'cfg:security.admin_password=' "$GRAFANA_CONF"; then
	PW=$(sed -n 's/^cfg:security.admin_password=//p' "$GRAFANA_CONF" | head -1)
	NEW_PW=0
else
	PW=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
	NEW_PW=1
fi
sed "s|__GRAFANA_ADMIN_PASSWORD__|$PW|" "$SRC/etc/conf.d/grafana.tmpl" > "$GRAFANA_CONF.new"
install -m 640 -o root -g grafana "$GRAFANA_CONF.new" "$GRAFANA_CONF"
rm -f "$GRAFANA_CONF.new"

# alertmanager: leave a working telegram config in place if it was already set up
install -m 644 -o root -g prometheus "$SRC/etc/alertmanager/alertmanager.telegram.tmpl" \
	/etc/alertmanager/alertmanager.telegram.tmpl
if [ -s /etc/alertmanager/telegram_token ]; then
	log "keeping existing telegram receiver"
else
	install -m 644 -o root -g prometheus "$SRC/etc/alertmanager/alertmanager.null.yml" \
		/etc/alertmanager/alertmanager.yml
fi
install -m 755 "$SRC/scripts/set-telegram-alerts" /usr/local/bin/set-telegram-alerts

# grafana provisioning + dashboards
install -o grafana -g grafana -m 644 "$SRC/grafana/provisioning/datasources/victoriametrics.yml" \
	/var/lib/grafana/provisioning/datasources/victoriametrics.yml
install -o grafana -g grafana -m 644 "$SRC/grafana/provisioning/dashboards/provider.yml" \
	/var/lib/grafana/provisioning/dashboards/provider.yml
for f in "$SRC"/grafana/dashboards/*.json; do
	install -o grafana -g grafana -m 644 "$f" "/var/lib/grafana/dashboards/$(basename "$f")"
done

# ---------------------------------------------------------------- firewall
log "firewall (LAN_CIDR=$LAN_CIDR)"
sed "s|__LAN_CIDR__|$LAN_CIDR|" "$SRC/etc/nftables.d/60_monitoring.nft.tmpl" \
	> /etc/nftables.d/60_monitoring.nft
chmod 644 /etc/nftables.d/60_monitoring.nft
nft -c -f /etc/nftables.nft
rc-service nftables restart >/dev/null

# ---------------------------------------------------------------- dev env
if [ "${WITH_DEV:-0}" = 1 ]; then
	log "dev profile"
	install -m 644 "$SRC/scripts/dev-toolchains.sh" /etc/profile.d/dev-toolchains.sh
fi

# ---------------------------------------------------------------- services
log "services"
for s in victoria-metrics node-exporter alertmanager vmalert grafana; do
	rc-update add "$s" default >/dev/null 2>&1 || true
done
for s in victoria-metrics node-exporter alertmanager vmalert grafana; do
	rc-service "$s" restart >/dev/null 2>&1 || rc-service "$s" start
done

log "done"
if [ "$NEW_PW" = 1 ]; then
	echo
	echo "Grafana admin password: $PW"
	echo "(stored in $GRAFANA_CONF, mode 0640 root:grafana)"
fi
