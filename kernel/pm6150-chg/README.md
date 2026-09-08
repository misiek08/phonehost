# pm6150-chg — an 80 % charge cap on a driverless charger

The Redmi Note 9 Pro runs a mainline kernel with **no charger driver**. The only
power supplies are the read-only `qcom_qg` fuel gauge and the Type-C port, so
nothing in sysfs can stop charging and the cell sits at 100 % / ~4.44 V
permanently — measured 4.42–4.45 V, which is above `voltage_max_design` (4.40 V)
and the worst storage condition for a Li-ion cell.

## Why this is a small change, not a charger driver

Mainline implements charge inhibit in `drivers/power/supply/qcom_smbx.c` with a
single bit (commit `98d68b74ebb9`, "power: supply: qcom_smbx: allow disabling
charging"):

```c
#define USBIN_CMD_IL      0x340
#define USBIN_SUSPEND_BIT BIT(0)

case POWER_SUPPLY_PROP_STATUS:
    return regmap_update_bits(chip->regmap, chip->base + USBIN_CMD_IL,
                              USBIN_SUSPEND_BIT, !val->intval);
```

That is the same `USBIN_SUSPEND` bit downstream Android exposes as
`/sys/class/power_supply/battery/input_suspend`, which every Xiaomi charge-limit
mod drives. It touches neither float voltage nor any current limit, so it has no
path to overcharging the cell. The worst outcome is "the phone stops taking
power and runs down", which the existing `MainsPowerLost` / `BatteryLow` alerts
already catch.

Enabling the full `CHARGER_QCOM_SMB2` driver instead would be the risky option:
its probe writes an init sequence (`smb_init_seq[]`) including Type-C role
control around 0x1500, which on this PMIC belongs to the already-working
`qcom,pm6150-typec` driver. This module deliberately avoids that.

## What is known

| Fact | Source |
|---|---|
| PM6150 carries an SMB5 charger block, `qcom,qpnp-smb5`, `chgr@1000`, `reg <0x1000 0x100>` | downstream vendor DTs (Realme/Samsung/Xiaomi sm6250-class trees) |
| Register offsets (`0x06`, `0x42`, `0x308`, `0x310`, `0x340`) and the charger-state enum | mainline `qcom_smbx.c` / this kernel's `qcom_pmi8998_charger.c` |
| Mainline SMB5 support (`qcom,pm7250b-charger`, `qcom,pm8150b-charger`) exists but is **unmerged**, and covers neither pm6150 nor this fork | Casey Connolly's series, 2025-06-19 |
| The regmap is reachable from a child of the SPMI device: `dev_get_regmap(dev->parent, NULL)` | `qcom_qg.c` in this kernel |
| No module signing, no MODVERSIONS (`CONFIG_MODULES=y` only) | phone's `/proc/config.gz` |
| Kernel built with clang 22.1.8 + LLD, no CFI, no LTO | `/proc/version`, `CONFIG_CC_IS_CLANG=y` |

So an out-of-tree module can be loaded with `insmod` — **no DTB change, no
boot.img flash, no signing**. Rollback is `rmmod`.

## Stage 1 (this module): read only

`pm6150_chg.c` finds pmic@0 through the `qcom,pm6150-qg` node (both pmic@0 and
pmic@1 share compatible `qcom,pm6150`; only pmic@0 has the gauge), takes the
MFD's regmap and reads five registers plus the peripheral type/subtype ids.
There is not a single register write in the file.

    insmod pm6150_chg.ko
    cat /sys/kernel/pm6150_chg/regs

What confirms the assumption:

* `PERPH_TYPE` / `USB_PERPH_TYPE` are neither `0x00` nor `0xff` — something real
  answers at 0x1000 and 0x1300
* `CHARGER_STATUS_1` decodes to a sensible state (`TERMINATE_CHARGE` on a full
  battery, `FAST_CHARGE` while filling)
* `APSD_RESULT_STATUS` says `SDP` when hanging off a PC port, `DCP` on a charger
* `USB_INT_RT_STS` has `plugin=1` with the cable in, `0` with it out
* `USBIN_CMD_IL` reads `usbin_suspend=0` while charging

If the type ids read as `0x00`/`0xff`, or plugin does not follow the cable, the
base is wrong or the block is not accessible — and stage 2 must not happen.

### Stage 1 result

Confirmed on the device, cable out and cable in:

| field | unplugged | plugged |
|---|---|---|
| `PERPH_TYPE` / `SUBTYPE` | 0x02 / 0x80 | same — real CHGR peripheral at 0x1000 |
| `USB_PERPH_TYPE` / `SUBTYPE` | 0x02 / 0x83 | same — distinct USB block at 0x1300 |
| `CHARGER_STATUS_1` | 0x47 `DISABLE_CHARGE` | 0x03 `FULLON_CHARGE` |
| `USB_INT_RT_STS` | 0x26 plugin=0 uv=1 lt3p6v=1 | 0x10 plugin=1 uv=0 lt3p6v=0 |
| gauge | +0.23 A, draining | −0.19 A, filling |

The register map tracks the physical cable in both directions, so the layout is
the assumed one.

## Stage 2 (done): charge_behaviour

`CHARGING_ENABLE_CMD` turned out to be the better lever of the two and became
the default. Measured with the cable in:

    inhibit-charge   CHARGING_ENABLE_CMD=0, plugin=1
                     battery current exactly 0 µA over five samples,
                     level held, voltage relaxed from 4.37 V to 4.30 V
    force-discharge  USBIN_SUSPEND=1, plugin=1
                     +0.02 A, voltage sagging - the system runs off the battery
    auto             both bits back, FULLON_CHARGE, −0.19 A

So charging can be stopped with **no cycling, no discharging, no heat and no
wasted power** — the cell simply rests at 0 A instead of floating at 4.44 V.

Both are exposed on `qcom_qg` through the power-supply extension API:

    echo auto            > /sys/class/power_supply/qcom_qg/charge_behaviour
    echo inhibit-charge  > /sys/class/power_supply/qcom_qg/charge_behaviour
    echo force-discharge > /sys/class/power_supply/qcom_qg/charge_behaviour

`STATUS` could not be extended (`qcom_qg` hardcodes it to `Unknown` and
`power_supply_register_extension()` rejects a property the base driver already
owns — which is also why no battery indicator can ever show "charging" on this
phone), so the real charger state is published separately:

    cat /sys/kernel/pm6150_chg/status      # Charging / Not charging / Full / Discharging
    cat /sys/kernel/pm6150_chg/regs        # raw registers, decoded

Charging is restored on module load *and* unload, because the PMIC keeps these
bits across a warm reboot: a phone that rebooted while inhibited must not come
back up refusing to charge. `read_only=Y` as a module parameter reverts it to
stage-1 behaviour.

## The daemon

`daemon/chargecap` holds the level inside a band. Since `inhibit-charge` cannot
bring a level *down* (the input still powers the phone, so the battery sits
still), the control law needs all three levers:

    level > upper    force-discharge   come down into the band
    level = upper    inhibit-charge    hold at 0 A
    level <= lower   auto              refill
    inside the band  hold, never keep discharging
    level <= floor   auto, unconditionally

Charging is restored on SIGTERM, on any unreadable sysfs file and by the init
script's `stop_post` — verified in the log: `got terminated, shutting down` /
`charging restored on exit`. Metrics land in VictoriaMetrics as job `chargecap`
and drive the "Charge cap" row of the Grafana dashboard; `battery.yml` watches
that the cap keeps working (`ChargeCapUnavailable`, `ChargeCapWriteErrors`,
`BatteryAboveBand`, `BatteryFull`) and `MainsPowerLost` now excludes a
deliberate descent.

Band is set in `etc/conf.d/chargecap` (default 75–80 %, floor 60 %,
`CHARGECAP_DESCEND=yes`).

## Building

Cross-compiled in a container so the phone stays idle (it crashed once under a
sustained 8-core load, so builds do not run there):

    git clone --depth 1 -b linux-6.14.7 https://github.com/sm7125-mainline/linux
    ssh phone 'zcat /proc/config.gz' > phone.config

    docker run --rm \
        -v "$PWD/linux:/kernel" \
        -v "$PWD/kernel/pm6150-chg:/mod" \
        -v "$PWD:/work" \
        alpine:edge sh /work/build-module.sh

The build must produce exactly this vermagic, or `insmod` will refuse it:

    6.14.7-sm7125 SMP preempt mod_unload aarch64
