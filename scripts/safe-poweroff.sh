#!/bin/sh
# Power the phone off without leaving the charger inhibited.
#
#   sudo sh /home/user/phonehost/scripts/safe-poweroff.sh [--dry-run] [--force]
#
# Why this exists: the charge cap works by clearing CHARGING_ENABLE_CMD in the
# PM6150. The PMIC keeps that bit while the system is off - it stays powered so
# that off-mode charging can work - so a phone shut down while the cap holds
# "inhibit-charge" may sit there not charging at all. chargecap restores "auto"
# when it stops, but this checks it rather than trusting it.
#
# There is no wake-on-LAN here: after this, only the power button brings the
# phone back.
set -eu

DRY=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY=1 ;;
		--force) FORCE=1 ;;
		*) echo "unknown argument: $arg" >&2; exit 1 ;;
	esac
done

if [ "$(id -u)" != 0 ]; then
	echo "run as root: sudo sh $0" >&2
	exit 1
fi

CB=/sys/class/power_supply/qcom_qg/charge_behaviour
log() { printf '\033[1;32m==\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- charge cap
if [ -e "$CB" ]; then
	if rc-service chargecap status >/dev/null 2>&1; then
		if [ "$DRY" = 1 ]; then
			log "chargecap is running - a real run would stop it, which restores charging"
		else
			log "stopping chargecap so it restores charging"
			rc-service chargecap stop
		fi
	fi

	behaviour=$(tr ' ' '\n' < "$CB" | grep '^\[' | tr -d '[]' || true)
	if [ "$behaviour" != auto ]; then
		if [ "$DRY" = 1 ]; then
			log "charge behaviour is '$behaviour' - a real run would force auto here"
		else
			log "charge behaviour is '$behaviour', forcing auto"
			echo auto > "$CB"
			behaviour=$(tr ' ' '\n' < "$CB" | grep '^\[' | tr -d '[]' || true)
		fi
	fi

	if [ "$behaviour" != auto ] && [ "$DRY" = 0 ]; then
		echo "charge behaviour is still '$behaviour' - powering off now could" >&2
		echo "leave the phone unable to charge while off. Fix it or pass --force." >&2
		[ "$FORCE" = 1 ] || exit 1
	fi
	if [ "$DRY" = 1 ]; then
		log "charge behaviour now: $behaviour (unchanged, dry run)"
	else
		log "charge behaviour now: $behaviour"
	fi
else
	log "no charge_behaviour control (pm6150_chg not loaded) - nothing to restore"
fi

# ---------------------------------------------------------------- state
log "battery $(cat /sys/class/power_supply/qcom_qg/capacity)%, $(cat /sys/kernel/pm6150_chg/status 2>/dev/null || echo 'charger state unknown')"

# VictoriaMetrics flushes on stop (conf.d gives it retry=30); the shutdown
# runlevel stops it in dependency order, so just make sure nothing is pending.
log "flushing filesystems"
[ "$DRY" = 1 ] || sync

if [ "$DRY" = 1 ]; then
	log "dry run - not powering off"
	exit 0
fi

log "powering off (init runs the OpenRC shutdown runlevel; only the power button revives it)"
exec poweroff
