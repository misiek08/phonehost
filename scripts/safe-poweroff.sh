#!/bin/sh
# Power the phone off without leaving the charger inhibited.
#
#   sudo sh /home/user/phonehost/scripts/safe-poweroff.sh [--dry-run] [--force]
#                                                         [--keep-cable-wakeup]
#
# Why this exists: the charge cap works by clearing CHARGING_ENABLE_CMD in the
# PM6150. The PMIC keeps that bit while the system is off - it stays powered so
# that off-mode charging can work - so a phone shut down while the cap holds
# "inhibit-charge" may sit there not charging at all. chargecap restores "auto"
# when it stops, but this checks it rather than trusting it.
#
# It also masks the PMIC's cable power-on trigger (CBL in the PON block), which
# is why a phone powered off with a charger connected switches straight back on.
#
# MEASURED: that masking does NOT work on this device. The write takes effect at
# runtime (TRIGGER_EN 0xe4 -> 0xa4) but the register is back to 0xe4 before Linux
# loads the module on the next boot, so either the PMIC resets the PON config in
# its power-on sequence or the bootloader reprograms it - Android needs
# charger-insertion boots for off-mode charging. Nothing in Linux runs later than
# PS_HOLD dropping, so this cannot be fixed from here.
#
# To keep the phone off, unplug the cable. The masking is left in place because
# it is harmless and costs nothing if a future bootloader stops overriding it.
# --keep-cable-wakeup skips it.
#
# There is no wake-on-LAN here: after this, only the power button brings the
# phone back.
set -eu

DRY=0
FORCE=0
KEEP_WAKEUP=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY=1 ;;
		--force) FORCE=1 ;;
		--keep-cable-wakeup) KEEP_WAKEUP=1 ;;
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

# ---------------------------------------------------------------- power-on trigger
CW=/sys/kernel/pm6150_chg/cable_wakeup
if [ -e "$CW" ] && [ "$KEEP_WAKEUP" = 0 ]; then
	if [ "$DRY" = 1 ]; then
		log "cable wakeup is $(cat "$CW") - a real run would mask it so the charger cannot switch the phone back on"
	else
		echo 0 > "$CW" || true
		if [ "$(cat "$CW")" = 0 ]; then
			log "cable wakeup masked - but see the note below: it does not survive"
			log "  power-off on this device, so a connected charger WILL boot it again"
		else
			log "could not mask cable wakeup - a connected charger will boot it again"
		fi
	fi
elif [ "$KEEP_WAKEUP" = 1 ]; then
	log "leaving cable wakeup armed as asked - a connected charger will switch the phone back on"
else
	log "no cable_wakeup control (pm6150_chg not loaded) - a connected charger will switch the phone back on"
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
