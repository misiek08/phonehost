// SPDX-License-Identifier: GPL-2.0-only
/*
 * pm6150_chg - read-only inspection of the SMB5 charger block in the PM6150.
 *
 * Stage 1 of putting an 80 % charge cap on a mainline-kernel Redmi Note 9 Pro
 * (sm7125 / miatoll). Mainline has no charger driver for this PMIC - the only
 * power supplies are the read-only qcom_qg fuel gauge and the Type-C port - so
 * nothing in sysfs can stop charging and the battery floats at 100 % / 4.44 V
 * forever.
 *
 * Downstream vendor trees describe the block as "qcom,qpnp-smb5" with
 * chgr@1000 (reg <0x1000 0x100>), and mainline's drivers/power/supply/
 * qcom_smbx.c supplies the register offsets. Before anything writes
 * USBIN_SUSPEND (USBIN_CMD_IL bit 0, which is how mainline's
 * "power: supply: qcom_smbx: allow disabling charging" implements charge
 * inhibit), this module confirms the layout is what we think it is.
 *
 * It contains no register writes, on purpose. Every regmap call here is a read.
 *
 * The regmap comes from the PMIC's MFD parent: the qgauge platform device is a
 * child of the SPMI device for pmic@0, and drivers/mfd/qcom-spmi-pmic.c
 * attaches a regmap to it (the same way qcom_qg.c obtains one).
 */

#include <linux/bits.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
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
/* The USB input block has its own peripheral id at 0x300 + 0x04/0x05 */
#define USB_PERPH_TYPE			0x304
#define USB_PERPH_SUBTYPE		0x305

static unsigned int chgr_base = 0x1000;
module_param(chgr_base, uint, 0444);
MODULE_PARM_DESC(chgr_base,
		 "SPMI base address of the charger block (default 0x1000, from downstream pm6150.dtsi)");

static struct regmap *pmic_regmap;
static struct kobject *pm6150_chg_kobj;

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

static struct kobj_attribute regs_attr = __ATTR_RO(regs);

static struct attribute *pm6150_chg_attrs[] = {
	&regs_attr.attr,
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

	if (!type || type == 0xff)
		pr_warn("pm6150_chg: peripheral type 0x%02x looks wrong - the charger block may not be at this base\n",
			type);

	pm6150_chg_kobj = kobject_create_and_add("pm6150_chg", kernel_kobj);
	if (!pm6150_chg_kobj)
		return -ENOMEM;

	ret = sysfs_create_groups(pm6150_chg_kobj, pm6150_chg_groups);
	if (ret) {
		kobject_put(pm6150_chg_kobj);
		return ret;
	}

	pr_info("pm6150_chg: read-only, see /sys/kernel/pm6150_chg/regs\n");
	return 0;
}

static void __exit pm6150_chg_exit(void)
{
	sysfs_remove_groups(pm6150_chg_kobj, pm6150_chg_groups);
	kobject_put(pm6150_chg_kobj);
}

module_init(pm6150_chg_init);
module_exit(pm6150_chg_exit);

MODULE_DESCRIPTION("Read-only inspection of the PM6150 SMB5 charger block");
MODULE_LICENSE("GPL");
