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
#   WITH_PODMAN=1                  also set up rootless podman + cgroup delegation
#   WITH_SCREENOFF=1               also make the Sxmo session start with the
#                                  screen off (installs a user hook)
#   WITH_CHARGECAP=1               also install the charge cap (needs the module
#                                  and the daemon built beforehand, see
#                                  kernel/pm6150-chg/README.md)
#   CHARGECAP_KO=<path>            pm6150_chg.ko to install (default $SRC/pm6150_chg.ko)
#   CHARGECAP_BIN=<path>           chargecap binary   (default $SRC/chargecap)
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
	apk add --quiet sqlite curl iw "$@"

	if [ "${WITH_PODMAN:-0}" = 1 ]; then
		log "podman packages"
		if [ "${PIN:-0}" = 1 ]; then
			apk add --quiet "podman=$PODMAN_VER" "podman-docker=$PODMAN_VER" \
				"podman-openrc=$PODMAN_VER" "podman-compose=$PODMAN_COMPOSE_VER" \
				crun netavark aardvark-dns fuse-overlayfs passt slirp4netns \
				shadow-subids catatonit
		else
			apk add --quiet podman podman-docker podman-openrc podman-compose \
				crun netavark aardvark-dns fuse-overlayfs passt slirp4netns \
				shadow-subids catatonit
		fi
	fi

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
install -m 755 "$SRC/etc/init.d/no-suspend"       /etc/init.d/no-suspend
install -m 755 "$SRC/etc/init.d/wifi-powersave-off" /etc/init.d/wifi-powersave-off

# WiFi power save makes this host unreachable from the LAN; see the file itself
install -d -m 755 /etc/NetworkManager/conf.d
install -m 644 "$SRC/etc/NetworkManager/conf.d/10-no-wifi-powersave.conf" \
	/etc/NetworkManager/conf.d/10-no-wifi-powersave.conf

# logbookd only writes its database when told to, so flush it on a schedule
install -d -m 755 /etc/periodic/15min
install -m 755 "$SRC/etc/periodic/15min/logbookd-save" /etc/periodic/15min/logbookd-save
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

# ---------------------------------------------------------------- podman
if [ "${WITH_PODMAN:-0}" = 1 ]; then
	PODMAN_USER=${PODMAN_USER:-user}
	log "podman rootless setup for $PODMAN_USER"

	# subuid/subgid ranges: without them podman falls back to a single-uid
	# mapping and many images break
	for f in /etc/subuid /etc/subgid; do
		[ -f "$f" ] || : > "$f"
		grep -q "^$PODMAN_USER:" "$f" || echo "$PODMAN_USER:100000:65536" >> "$f"
		chmod 644 "$f"
	done

	# fuse-overlayfs storage and the overlay driver are modules here
	printf 'fuse\noverlay\n' > /etc/modules-load.d/podman.conf
	modprobe fuse 2>/dev/null || true
	modprobe overlay 2>/dev/null || true

	install -m 755 "$SRC/scripts/local.d/10-podman-shared-mount.start" \
		/etc/local.d/10-podman-shared-mount.start
	sh /etc/local.d/10-podman-shared-mount.start
	rc-update add local default >/dev/null 2>&1 || true

	install -m 644 "$SRC/etc/conf.d/podman" /etc/conf.d/podman
	# local init script: tolerates a missing /run/user/<uid> at boot, see header
	install -m 755 "$SRC/etc/init.d/podman" /etc/init.d/podman
	rc-update add podman default >/dev/null 2>&1 || true

	# Delegated cgroup v2 subtree: without it rootless podman silently ignores
	# --memory/--cpus/--pids-limit (there is no systemd user manager here).
	install -m 755 "$SRC/etc/init.d/cgroup-delegate" /etc/init.d/cgroup-delegate
	install -m 644 "$SRC/etc/conf.d/cgroup-delegate" /etc/conf.d/cgroup-delegate
	install -d -m 755 /usr/local/sbin
	install -m 755 "$SRC/scripts/cg-attach" /usr/local/sbin/cg-attach
	install -m 644 "$SRC/scripts/profile.d/cgroup-delegate.sh" \
		/etc/profile.d/cgroup-delegate.sh
	rc-update add cgroup-delegate default >/dev/null 2>&1 || true
	rc-service cgroup-delegate restart >/dev/null 2>&1 || \
		rc-service cgroup-delegate start >/dev/null 2>&1 || true

	su "$PODMAN_USER" -s /bin/sh -c 'podman system migrate' >/dev/null 2>&1 || true
	rc-service podman restart >/dev/null 2>&1 || rc-service podman start >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- screen off
if [ "${WITH_SCREENOFF:-0}" = 1 ]; then
	SXMO_USER=${SXMO_USER:-user}
	SXMO_HOME=$(getent passwd "$SXMO_USER" | cut -d: -f6)
	log "Sxmo session starts with the screen off ($SXMO_USER)"

	install -d -o "$SXMO_USER" -g "$SXMO_USER" -m 755 \
		"$SXMO_HOME/.config/sxmo/hooks"
	install -o "$SXMO_USER" -g "$SXMO_USER" -m 755 \
		"$SRC/sxmo/hooks/sxmo_hook_start.sh" \
		"$SXMO_HOME/.config/sxmo/hooks/sxmo_hook_start.sh"
fi

# ---------------------------------------------------------------- charge cap
if [ "${WITH_CHARGECAP:-0}" = 1 ]; then
	log "charge cap"
	KO=${CHARGECAP_KO:-$SRC/pm6150_chg.ko}
	BIN=${CHARGECAP_BIN:-$SRC/chargecap}
	KV=$(uname -r)

	if [ ! -f "$KO" ] || [ ! -f "$BIN" ]; then
		ewarn_missing="pm6150_chg.ko or chargecap binary missing"
		echo "  $ewarn_missing - build them first (see kernel/pm6150-chg/README.md)" >&2
		exit 1
	fi

	# The module is tied to this exact kernel; after a kernel upgrade it simply
	# will not load, which leaves charging enabled - the safe direction.
	install -d -m 755 "/lib/modules/$KV/extra"
	install -m 644 "$KO" "/lib/modules/$KV/extra/pm6150_chg.ko"
	depmod -a
	echo pm6150_chg > /etc/modules-load.d/pm6150-chg.conf
	modprobe pm6150_chg 2>/dev/null || insmod "/lib/modules/$KV/extra/pm6150_chg.ko" 2>/dev/null || true

	install -m 755 "$BIN" /usr/local/bin/chargecap
	install -m 755 "$SRC/etc/init.d/chargecap" /etc/init.d/chargecap
	install -m 644 "$SRC/etc/conf.d/chargecap" /etc/conf.d/chargecap
	rc-update add chargecap default >/dev/null 2>&1 || true
	rc-service chargecap restart >/dev/null 2>&1 || rc-service chargecap start >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- dev env
if [ "${WITH_DEV:-0}" = 1 ]; then
	log "dev profile"
	install -m 644 "$SRC/scripts/dev-toolchains.sh" /etc/profile.d/dev-toolchains.sh
fi

# ---------------------------------------------------------------- services
log "services"
for s in no-suspend wifi-powersave-off crond victoria-metrics node-exporter alertmanager vmalert grafana; do
	rc-update add "$s" default >/dev/null 2>&1 || true
done
for s in no-suspend wifi-powersave-off crond victoria-metrics node-exporter alertmanager vmalert grafana; do
	rc-service "$s" restart >/dev/null 2>&1 || rc-service "$s" start
done

log "done"
if [ "$NEW_PW" = 1 ]; then
	echo
	echo "Grafana admin password: $PW"
	echo "(stored in $GRAFANA_CONF, mode 0640 root:grafana)"
fi
