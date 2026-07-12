// SPDX-License-Identifier: GPL-2.0-only
/* System16 FPGA PS/2 Set-2 keyboard input driver. */
#include <linux/input.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/workqueue.h>

#define REG_STATUS 0x00
#define REG_KEY    0x04
#define STATUS_READY     BIT(0)
#define STATUS_RELEASE   BIT(1)
#define STATUS_EXTENDED  BIT(2)

struct gorv32_ps2 {
	void __iomem *base;
	struct input_dev *input;
	struct delayed_work poll_work;
	u32 poll_ms;
};

static const unsigned short set2_keys[256] = {
	[0x1c]=KEY_A,[0x32]=KEY_B,[0x21]=KEY_C,[0x23]=KEY_D,
	[0x24]=KEY_E,[0x2b]=KEY_F,[0x34]=KEY_G,[0x33]=KEY_H,
	[0x43]=KEY_I,[0x3b]=KEY_J,[0x42]=KEY_K,[0x4b]=KEY_L,
	[0x3a]=KEY_M,[0x31]=KEY_N,[0x44]=KEY_O,[0x4d]=KEY_P,
	[0x15]=KEY_Q,[0x2d]=KEY_R,[0x1b]=KEY_S,[0x2c]=KEY_T,
	[0x3c]=KEY_U,[0x2a]=KEY_V,[0x1d]=KEY_W,[0x22]=KEY_X,
	[0x35]=KEY_Y,[0x1a]=KEY_Z,
	[0x16]=KEY_1,[0x1e]=KEY_2,[0x26]=KEY_3,[0x25]=KEY_4,
	[0x2e]=KEY_5,[0x36]=KEY_6,[0x3d]=KEY_7,[0x3e]=KEY_8,
	[0x46]=KEY_9,[0x45]=KEY_0,
	[0x5a]=KEY_ENTER,[0x76]=KEY_ESC,[0x66]=KEY_BACKSPACE,
	[0x0d]=KEY_TAB,[0x29]=KEY_SPACE,[0x4e]=KEY_MINUS,
	[0x55]=KEY_EQUAL,[0x54]=KEY_LEFTBRACE,[0x5b]=KEY_RIGHTBRACE,
	[0x5d]=KEY_BACKSLASH,[0x61]=KEY_102ND,[0x4c]=KEY_SEMICOLON,
	[0x52]=KEY_APOSTROPHE,[0x0e]=KEY_GRAVE,[0x41]=KEY_COMMA,
	[0x49]=KEY_DOT,[0x4a]=KEY_SLASH,[0x58]=KEY_CAPSLOCK,
	[0x12]=KEY_LEFTSHIFT,[0x59]=KEY_RIGHTSHIFT,
	[0x14]=KEY_LEFTCTRL,[0x11]=KEY_LEFTALT,
	[0x05]=KEY_F1,[0x06]=KEY_F2,[0x04]=KEY_F3,[0x0c]=KEY_F4,
	[0x03]=KEY_F5,[0x0b]=KEY_F6,[0x83]=KEY_F7,[0x0a]=KEY_F8,
	[0x01]=KEY_F9,[0x09]=KEY_F10,[0x78]=KEY_F11,[0x07]=KEY_F12,
	[0x77]=KEY_NUMLOCK,[0x7c]=KEY_KPASTERISK,[0x7b]=KEY_KPMINUS,
	[0x79]=KEY_KPPLUS,[0x69]=KEY_KP1,[0x72]=KEY_KP2,
	[0x7a]=KEY_KP3,[0x6b]=KEY_KP4,[0x73]=KEY_KP5,
	[0x74]=KEY_KP6,[0x6c]=KEY_KP7,[0x75]=KEY_KP8,
	[0x7d]=KEY_KP9,[0x70]=KEY_KP0,[0x71]=KEY_KPDOT,
};

static const unsigned short set2_ext_keys[256] = {
	[0x14]=KEY_RIGHTCTRL,[0x11]=KEY_RIGHTALT,
	[0x1f]=KEY_LEFTMETA,[0x27]=KEY_RIGHTMETA,[0x2f]=KEY_MENU,
	[0x70]=KEY_INSERT,[0x6c]=KEY_HOME,[0x7d]=KEY_PAGEUP,
	[0x71]=KEY_DELETE,[0x69]=KEY_END,[0x7a]=KEY_PAGEDOWN,
	[0x74]=KEY_RIGHT,[0x6b]=KEY_LEFT,[0x72]=KEY_DOWN,[0x75]=KEY_UP,
	[0x4a]=KEY_KPSLASH,[0x5a]=KEY_KPENTER,
};

static void gorv32_ps2_poll(struct work_struct *work)
{
	struct gorv32_ps2 *ps2 = container_of(to_delayed_work(work),
						struct gorv32_ps2, poll_work);
	u32 status = readl(ps2->base + REG_STATUS) & 0xff;

	if (status & STATUS_READY) {
		u8 scan = readl(ps2->base + REG_KEY) & 0xff;
		unsigned short code = (status & STATUS_EXTENDED) ?
			set2_ext_keys[scan] : set2_keys[scan];

		if (code) {
			input_report_key(ps2->input, code,
					 !(status & STATUS_RELEASE));
			input_sync(ps2->input);
		}
	}
	schedule_delayed_work(&ps2->poll_work,
			      msecs_to_jiffies(ps2->poll_ms));
}

static int gorv32_ps2_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct gorv32_ps2 *ps2;
	struct input_dev *input;
	unsigned int i;
	int ret;

	ps2 = devm_kzalloc(dev, sizeof(*ps2), GFP_KERNEL);
	if (!ps2)
		return -ENOMEM;
	ps2->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(ps2->base))
		return PTR_ERR(ps2->base);
	ps2->poll_ms = 10;
	of_property_read_u32(dev->of_node, "poll-interval-ms", &ps2->poll_ms);
	ps2->poll_ms = clamp_val(ps2->poll_ms, 10, 100);

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;
	ps2->input = input;
	input->name = "System16 FPGA PS/2 keyboard";
	input->phys = "system16-ps2/input0";
	input->id.bustype = BUS_I8042;
	input->dev.parent = dev;
	__set_bit(EV_KEY, input->evbit);
	__set_bit(EV_REP, input->evbit);
	for (i = 0; i < ARRAY_SIZE(set2_keys); i++) {
		if (set2_keys[i])
			__set_bit(set2_keys[i], input->keybit);
		if (set2_ext_keys[i])
			__set_bit(set2_ext_keys[i], input->keybit);
	}

	ret = input_register_device(input);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, ps2);
	INIT_DELAYED_WORK(&ps2->poll_work, gorv32_ps2_poll);
	schedule_delayed_work(&ps2->poll_work, 0);
	dev_info(dev, "PS/2 Set-2 keyboard polling every %u ms\n", ps2->poll_ms);
	return 0;
}

static void gorv32_ps2_remove(struct platform_device *pdev)
{
	struct gorv32_ps2 *ps2 = platform_get_drvdata(pdev);
	cancel_delayed_work_sync(&ps2->poll_work);
}

static const struct of_device_id gorv32_ps2_of_match[] = {
	{ .compatible = "gowin,system16-ps2" }, { }
};
MODULE_DEVICE_TABLE(of, gorv32_ps2_of_match);

static struct platform_driver gorv32_ps2_driver = {
	.probe = gorv32_ps2_probe,
	.remove = gorv32_ps2_remove,
	.driver = { .name = "gorv32-ps2", .of_match_table = gorv32_ps2_of_match },
};
module_platform_driver(gorv32_ps2_driver);

MODULE_DESCRIPTION("System16 FPGA PS/2 keyboard");
MODULE_LICENSE("GPL");
