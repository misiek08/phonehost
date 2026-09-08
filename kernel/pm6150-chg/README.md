# pm6150-chg — towards an 80 % charge cap

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

## Stage 2 (only after stage 1 checks out)

Add a write path for `USBIN_SUSPEND` exposed as the standard
`POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR` on `qcom_qg` via the power-supply extension
API (`power_supply_register_extension`, present in 6.14 — the
`/sys/class/power_supply/qcom_qg/extensions/` directory already exists):

    echo inhibit-charge > /sys/class/power_supply/qcom_qg/charge_behaviour
    echo auto           > /sys/class/power_supply/qcom_qg/charge_behaviour

Then a small hysteresis daemon (80 % → inhibit, 70 % → auto) as an OpenRC
service, with its state exported to VictoriaMetrics and a Grafana panel.

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
