// SPDX-License-Identifier: GPL-2.0-only
/*
 * pm6150_chg - charge control for the SMB5 charger block in the PM6150.
 *
 * Mainline has no charger driver for this PMIC: on a Redmi Note 9 Pro
 * (sm7125 / miatoll) the only power supplies are the read-only qcom_qg fuel
 * gauge and the Type-C port, so nothing in sysfs can stop charging and the
 * battery floats at 100 % / ~4.44 V forever - measured above the cell's
 * voltage_max_design of 4.40 V, which is the worst storage condition there is.
 *
 * Rather than port the (still unmerged) SMB5 support of
 * drivers/power/supply/qcom_smbx.c, whose probe writes a whole init sequence
 * including Type-C role control that belongs to the pm6150-typec driver, this
 * module only ever touches two single bits of the charger block:
 *
 *   CHARGING_ENABLE_CMD bit 0 - stop charging the battery, keep the USB input
 *                               powering the system   -> inhibit-charge
 *   USBIN_SUSPEND      bit 0  - suspend the USB input entirely, so the system
 *                               runs off the battery  -> force-discharge
 *
 * Neither touches float voltage or any current limit, so there is no path to
 * overcharging the cell. The failure mode is "stops taking power", which the
 * host's MainsPowerLost / BatteryLow alerts already catch.
 *
 * Control is exposed as the standard POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR on the
 * existing qcom_qg power supply through the power-supply extension API:
 *
 *   echo auto            > /sys/class/power_supply/qcom_qg/charge_behaviour
 *   echo inhibit-charge  > /sys/class/power_supply/qcom_qg/charge_behaviour
 *   echo force-discharge > /sys/class/power_supply/qcom_qg/charge_behaviour
 *
 * STATUS cannot be extended (qcom_qg already provides it, hardcoded to
 * Unknown, and power_supply_register_extension() rejects duplicates), so the
 * real charger state is reported in /sys/kernel/pm6150_chg/status instead.
 *
 * Charging is restored both when the module is loaded and when it is unloaded:
 * the PMIC keeps these bits across a warm reboot, so a phone that rebooted
 * while inhibited must not come back up refusing to charge.
 */

#include <linux/bits.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/sysfs.h>

/* Offsets relative to the charger base, from mainline qcom_smbx.c */
#define PERPH_TYPE			0x04
#define PERPH_SUBTYPE			0x05
#define BATTERY_CHARGER_STATUS_1	0x06
#define BATTERY_CHARGER_STATUS_MASK	GENMASK(2, 0)
#define CHARGING_ENABLE_CMD		0x42
#define CHARGING_ENABLE_CMD_BIT		BIT(0)
#define APSD_RESULT_STATUS		0x308
#define APSD_RESULT_STATUS_MASK		GENMASK(6, 0)
#define   SDP_CHARGER_BIT		BIT(0)
#define   OCP_CHARGER_BIT		BIT(1)
#define   CDP_CHARGER_BIT		BIT(2)
#define   DCP_CHARGER_BIT		BIT(3)
#define   FLOAT_CHARGER_BIT		BIT(4)
#define INT_RT_STS			0x310
#define   USBIN_COLLAPSE_RT_STS_BIT	BIT(0)
#define   USBIN_LT_3P6V_RT_STS_BIT	BIT(1)
#define   USBIN_UV_RT_STS_BIT		BIT(2)
#define   USBIN_OV_RT_STS_BIT		BIT(3)
#define   USBIN_PLUGIN_RT_STS_BIT	BIT(4)
#define USBIN_CMD_IL			0x340
#define   USBIN_SUSPEND_BIT		BIT(0)
/* The USB input block carries its own peripheral id at 0x300 + 0x04/0x05 */
#define USB_PERPH_TYPE			0x304
#define USB_PERPH_SUBTYPE		0x305

static unsigned int chgr_base = 0x1000;
module_param(chgr_base, uint, 0444);
MODULE_PARM_DESC(chgr_base,
		 "SPMI base address of the charger block (default 0x1000, from downstream pm6150.dtsi)");

static bool read_only;
module_param(read_only, bool, 0444);
MODULE_PARM_DESC(read_only,
		 "Register the extension read-only, never write a charger bit (default N)");

static struct regmap *pmic_regmap;
static struct kobject *pm6150_chg_kobj;
static struct power_supply *battery_psy;
static enum power_supply_charge_behaviour current_behaviour =
	POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO;

static const char * const charger_status[] = {
	"TRICKLE_CHARGE", "PRE_CHARGE", "FAST_CHARGE", "FULLON_CHARGE",
	"TAPER_CHARGE", "TERMINATE_CHARGE", "INHIBIT_CHARGE", "DISABLE_CHARGE",
};

static const char *apsd_name(unsigned int stat)
{
	if (stat & CDP_CHARGER_BIT)
		return "CDP";
	if (stat & DCP_CHARGER_BIT)
		return "DCP";
	if (stat & OCP_CHARGER_BIT)
		return "OCP";
	if (stat & FLOAT_CHARGER_BIT)
		return "FLOAT";
	if (stat & SDP_CHARGER_BIT)
		return "SDP";
	return "none";
}

static int read_reg(unsigned int off, unsigned int *val)
{
	return regmap_read(pmic_regmap, chgr_base + off, val);
}

static int write_bit(unsigned int off, unsigned int mask, bool set)
{
	if (read_only) {
		pr_warn("pm6150_chg: read_only=Y, refusing to write 0x%04x\n",
			chgr_base + off);
		return -EPERM;
	}

	return regmap_update_bits(pmic_regmap, chgr_base + off, mask,
				  set ? mask : 0);
}

/*
 * auto:            charging enabled, input live
 * inhibit-charge:  charging disabled, input live (system still runs off USB)
 * force-discharge: input suspended, so the system drains the battery
 */
static int apply_behaviour(enum power_supply_charge_behaviour behaviour)
{
	int ret;

	switch (behaviour) {
	case POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO:
		ret = write_bit(USBIN_CMD_IL, USBIN_SUSPEND_BIT, false);
		if (ret)
			return ret;
		ret = write_bit(CHARGING_ENABLE_CMD, CHARGING_ENABLE_CMD_BIT, true);
		break;
	case POWER_SUPPLY_CHARGE_BEHAVIOUR_INHIBIT_CHARGE:
		ret = write_bit(USBIN_CMD_IL, USBIN_SUSPEND_BIT, false);
		if (ret)
			return ret;
		ret = write_bit(CHARGING_ENABLE_CMD, CHARGING_ENABLE_CMD_BIT, false);
		break;
	case POWER_SUPPLY_CHARGE_BEHAVIOUR_FORCE_DISCHARGE:
		/* keep the charge FSM enabled; the input is what gets cut */
		ret = write_bit(CHARGING_ENABLE_CMD, CHARGING_ENABLE_CMD_BIT, true);
		if (ret)
			return ret;
		ret = write_bit(USBIN_CMD_IL, USBIN_SUSPEND_BIT, true);
		break;
	default:
		return -EINVAL;
	}

	if (!ret) {
		current_behaviour = behaviour;
		if (battery_psy)
			power_supply_changed(battery_psy);
	}

	return ret;
}

/* Reports what the hardware says, not what was last requested. */
static int read_behaviour(enum power_supply_charge_behaviour *behaviour)
{
	unsigned int cmd_il, enable;
	int ret;

	ret = read_reg(USBIN_CMD_IL, &cmd_il);
	if (ret)
		return ret;
	ret = read_reg(CHARGING_ENABLE_CMD, &enable);
	if (ret)
		return ret;

	if (cmd_il & USBIN_SUSPEND_BIT)
		*behaviour = POWER_SUPPLY_CHARGE_BEHAVIOUR_FORCE_DISCHARGE;
	else if (!(enable & CHARGING_ENABLE_CMD_BIT))
		*behaviour = POWER_SUPPLY_CHARGE_BEHAVIOUR_INHIBIT_CHARGE;
	else
		*behaviour = POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO;

	return 0;
}

static int pm6150_chg_get_property(struct power_supply *psy,
				   const struct power_supply_ext *ext,
				   void *data, enum power_supply_property psp,
				   union power_supply_propval *val)
{
	enum power_supply_charge_behaviour behaviour;
	int ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR:
		ret = read_behaviour(&behaviour);
		if (ret)
			return ret;
		val->intval = behaviour;
		return 0;
	default:
		return -EINVAL;
	}
}

static int pm6150_chg_set_property(struct power_supply *psy,
				   const struct power_supply_ext *ext,
				   void *data, enum power_supply_property psp,
				   const union power_supply_propval *val)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR:
		return apply_behaviour(val->intval);
	default:
		return -EINVAL;
	}
}

static int pm6150_chg_property_is_writeable(struct power_supply *psy,
					    const struct power_supply_ext *ext,
					    void *data,
					    enum power_supply_property psp)
{
	return !read_only && psp == POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR;
}

static const enum power_supply_property pm6150_chg_properties[] = {
	POWER_SUPPLY_PROP_CHARGE_BEHAVIOUR,
};

static const struct power_supply_ext pm6150_chg_ext = {
	.name			= "pm6150_chg",
	.charge_behaviours	= BIT(POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO) |
				  BIT(POWER_SUPPLY_CHARGE_BEHAVIOUR_INHIBIT_CHARGE) |
				  BIT(POWER_SUPPLY_CHARGE_BEHAVIOUR_FORCE_DISCHARGE),
	.properties		= pm6150_chg_properties,
	.num_properties		= ARRAY_SIZE(pm6150_chg_properties),
	.get_property		= pm6150_chg_get_property,
	.set_property		= pm6150_chg_set_property,
	.property_is_writeable	= pm6150_chg_property_is_writeable,
};

static ssize_t regs_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	unsigned int type, subtype, usb_type, usb_subtype;
	unsigned int status1, enable, apsd, rt_sts, cmd_il;
	int len = 0, ret;

	ret = read_reg(PERPH_TYPE, &type);
	if (!ret)
		ret = read_reg(PERPH_SUBTYPE, &subtype);
	if (!ret)
		ret = read_reg(USB_PERPH_TYPE, &usb_type);
	if (!ret)
		ret = read_reg(USB_PERPH_SUBTYPE, &usb_subtype);
	if (!ret)
		ret = read_reg(BATTERY_CHARGER_STATUS_1, &status1);
	if (!ret)
		ret = read_reg(CHARGING_ENABLE_CMD, &enable);
	if (!ret)
		ret = read_reg(APSD_RESULT_STATUS, &apsd);
	if (!ret)
		ret = read_reg(INT_RT_STS, &rt_sts);
	if (!ret)
		ret = read_reg(USBIN_CMD_IL, &cmd_il);
	if (ret)
		return ret;

	len += sysfs_emit_at(buf, len, "chgr_base            0x%04x\n", chgr_base);
	len += sysfs_emit_at(buf, len, "PERPH_TYPE           0x%02x\n", type);
	len += sysfs_emit_at(buf, len, "PERPH_SUBTYPE        0x%02x\n", subtype);
	len += sysfs_emit_at(buf, len, "USB_PERPH_TYPE       0x%02x\n", usb_type);
	len += sysfs_emit_at(buf, len, "USB_PERPH_SUBTYPE    0x%02x\n", usb_subtype);
	len += sysfs_emit_at(buf, len, "CHARGER_STATUS_1     0x%02x  state=%s\n",
			     status1,
			     charger_status[status1 & BATTERY_CHARGER_STATUS_MASK]);
	len += sysfs_emit_at(buf, len, "CHARGING_ENABLE_CMD  0x%02x  charging_enabled=%d\n",
			     enable, !!(enable & CHARGING_ENABLE_CMD_BIT));
	len += sysfs_emit_at(buf, len, "APSD_RESULT_STATUS   0x%02x  source=%s\n",
			     apsd, apsd_name(apsd & APSD_RESULT_STATUS_MASK));
	len += sysfs_emit_at(buf, len,
			     "USB_INT_RT_STS       0x%02x  plugin=%d ov=%d uv=%d lt3p6v=%d collapse=%d\n",
			     rt_sts,
			     !!(rt_sts & USBIN_PLUGIN_RT_STS_BIT),
			     !!(rt_sts & USBIN_OV_RT_STS_BIT),
			     !!(rt_sts & USBIN_UV_RT_STS_BIT),
			     !!(rt_sts & USBIN_LT_3P6V_RT_STS_BIT),
			     !!(rt_sts & USBIN_COLLAPSE_RT_STS_BIT));
	len += sysfs_emit_at(buf, len, "USBIN_CMD_IL         0x%02x  usbin_suspend=%d\n",
			     cmd_il, !!(cmd_il & USBIN_SUSPEND_BIT));

	return len;
}

/*
 * The charging status qcom_qg cannot report: it hardcodes
 * POWER_SUPPLY_PROP_STATUS to Unknown and the extension API refuses to
 * override a property the base driver already owns.
 */
static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	unsigned int status1, rt_sts, cmd_il, enable;
	const char *status;
	int ret;

	ret = read_reg(BATTERY_CHARGER_STATUS_1, &status1);
	if (!ret)
		ret = read_reg(INT_RT_STS, &rt_sts);
	if (!ret)
		ret = read_reg(USBIN_CMD_IL, &cmd_il);
	if (!ret)
		ret = read_reg(CHARGING_ENABLE_CMD, &enable);
	if (ret)
		return ret;

	if (!(rt_sts & USBIN_PLUGIN_RT_STS_BIT) || (cmd_il & USBIN_SUSPEND_BIT))
		status = "Discharging";
	else if (!(enable & CHARGING_ENABLE_CMD_BIT))
		status = "Not charging";
	else
		switch (status1 & BATTERY_CHARGER_STATUS_MASK) {
		case 0: /* TRICKLE_CHARGE */
		case 1: /* PRE_CHARGE */
		case 2: /* FAST_CHARGE */
		case 3: /* FULLON_CHARGE */
		case 4: /* TAPER_CHARGE */
			status = "Charging";
			break;
		case 5: /* TERMINATE_CHARGE */
			status = "Full";
			break;
		default: /* INHIBIT_CHARGE, DISABLE_CHARGE */
			status = "Not charging";
			break;
		}

	return sysfs_emit(buf, "%s\n", status);
}

static struct kobj_attribute regs_attr = __ATTR_RO(regs);
static struct kobj_attribute status_attr = __ATTR_RO(status);

static struct attribute *pm6150_chg_attrs[] = {
	&regs_attr.attr,
	&status_attr.attr,
	NULL,
};
ATTRIBUTE_GROUPS(pm6150_chg);

static int __init pm6150_chg_init(void)
{
	struct device_node *np;
	struct platform_device *pdev;
	unsigned int type, subtype, cmd_il;
	int ret;

	/*
	 * The fuel gauge node is a reliable handle on pmic@0: both pmic@0 and
	 * pmic@1 carry compatible "qcom,pm6150", but only pmic@0 has the
	 * qgauge child.
	 */
	np = of_find_compatible_node(NULL, NULL, "qcom,pm6150-qg");
	if (!np) {
		pr_err("pm6150_chg: no qcom,pm6150-qg node, wrong device?\n");
		return -ENODEV;
	}

	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev) {
		pr_err("pm6150_chg: qgauge device not instantiated yet\n");
		return -ENODEV;
	}

	pmic_regmap = dev_get_regmap(pdev->dev.parent, NULL);
	put_device(&pdev->dev);
	if (!pmic_regmap) {
		pr_err("pm6150_chg: no regmap on the PMIC parent\n");
		return -ENODEV;
	}

	/* Sanity: does anything answer at the assumed charger base? */
	ret = read_reg(PERPH_TYPE, &type);
	if (!ret)
		ret = read_reg(PERPH_SUBTYPE, &subtype);
	if (!ret)
		ret = read_reg(USBIN_CMD_IL, &cmd_il);
	if (ret) {
		pr_err("pm6150_chg: read at base 0x%04x failed: %d\n",
		       chgr_base, ret);
		return ret;
	}

	pr_info("pm6150_chg: base 0x%04x type 0x%02x subtype 0x%02x, USBIN_CMD_IL 0x%02x (suspend=%d)\n",
		chgr_base, type, subtype, cmd_il, !!(cmd_il & USBIN_SUSPEND_BIT));

	if (!type || type == 0xff) {
		pr_err("pm6150_chg: peripheral type 0x%02x looks wrong, refusing to bind\n",
		       type);
		return -ENODEV;
	}

	battery_psy = power_supply_get_by_name("qcom_qg");
	if (!battery_psy) {
		pr_err("pm6150_chg: qcom_qg power supply not registered\n");
		return -ENODEV;
	}

	pm6150_chg_kobj = kobject_create_and_add("pm6150_chg", kernel_kobj);
	if (!pm6150_chg_kobj) {
		ret = -ENOMEM;
		goto err_psy;
	}

	ret = sysfs_create_groups(pm6150_chg_kobj, pm6150_chg_groups);
	if (ret)
		goto err_kobj;

	ret = power_supply_register_extension(battery_psy, &pm6150_chg_ext,
					      &battery_psy->dev, NULL);
	if (ret) {
		pr_err("pm6150_chg: cannot extend qcom_qg: %d\n", ret);
		goto err_groups;
	}

	/*
	 * The PMIC keeps these bits across a warm reboot, so start from a known
	 * good state: charging on, input live.
	 */
	if (!read_only) {
		ret = apply_behaviour(POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO);
		if (ret)
			pr_warn("pm6150_chg: could not restore auto behaviour: %d\n",
				ret);
	}

	pr_info("pm6150_chg: charge_behaviour on qcom_qg%s, state in /sys/kernel/pm6150_chg/\n",
		read_only ? " (read-only)" : "");
	return 0;

err_groups:
	sysfs_remove_groups(pm6150_chg_kobj, pm6150_chg_groups);
err_kobj:
	kobject_put(pm6150_chg_kobj);
err_psy:
	power_supply_put(battery_psy);
	battery_psy = NULL;
	return ret;
}

static void __exit pm6150_chg_exit(void)
{
	/* never leave the phone unable to charge */
	if (!read_only)
		apply_behaviour(POWER_SUPPLY_CHARGE_BEHAVIOUR_AUTO);

	power_supply_unregister_extension(battery_psy, &pm6150_chg_ext);
	sysfs_remove_groups(pm6150_chg_kobj, pm6150_chg_groups);
	kobject_put(pm6150_chg_kobj);
	power_supply_put(battery_psy);
}

module_init(pm6150_chg_init);
module_exit(pm6150_chg_exit);

MODULE_DESCRIPTION("Charge behaviour control for the PM6150 SMB5 charger block");
MODULE_LICENSE("GPL");
