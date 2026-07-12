// SPDX-License-Identifier: GPL-2.0-only
/* System16 FPGA low-speed USB HID keyboard input driver. */
#include <linux/delay.h>
#include <linux/input.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/workqueue.h>

#define REG_STATUS 0x00
#define REG_KEY    0x04
#define REG_MOD    0x08
#define STATUS_READY BIT(0)
#define STATUS_CONNECTED BIT(7)

struct gorv32_usb_hid {
	void __iomem *base;
	struct input_dev *input;
	struct delayed_work poll_work;
	u32 poll_ms;
	u8 old_key;
	u8 old_mod;
	bool connected;
};

static const unsigned short hid_keys[256] = {
	[4] = KEY_A, [5] = KEY_B, [6] = KEY_C, [7] = KEY_D,
	[8] = KEY_E, [9] = KEY_F, [10] = KEY_G, [11] = KEY_H,
	[12] = KEY_I, [13] = KEY_J, [14] = KEY_K, [15] = KEY_L,
	[16] = KEY_M, [17] = KEY_N, [18] = KEY_O, [19] = KEY_P,
	[20] = KEY_Q, [21] = KEY_R, [22] = KEY_S, [23] = KEY_T,
	[24] = KEY_U, [25] = KEY_V, [26] = KEY_W, [27] = KEY_X,
	[28] = KEY_Y, [29] = KEY_Z,
	[30] = KEY_1, [31] = KEY_2, [32] = KEY_3, [33] = KEY_4,
	[34] = KEY_5, [35] = KEY_6, [36] = KEY_7, [37] = KEY_8,
	[38] = KEY_9, [39] = KEY_0,
	[40] = KEY_ENTER, [41] = KEY_ESC, [42] = KEY_BACKSPACE,
	[43] = KEY_TAB, [44] = KEY_SPACE, [45] = KEY_MINUS,
	[46] = KEY_EQUAL, [47] = KEY_LEFTBRACE, [48] = KEY_RIGHTBRACE,
	[49] = KEY_BACKSLASH, [50] = KEY_102ND, [51] = KEY_SEMICOLON,
	[52] = KEY_APOSTROPHE, [53] = KEY_GRAVE, [54] = KEY_COMMA,
	[55] = KEY_DOT, [56] = KEY_SLASH, [57] = KEY_CAPSLOCK,
	[58] = KEY_F1, [59] = KEY_F2, [60] = KEY_F3, [61] = KEY_F4,
	[62] = KEY_F5, [63] = KEY_F6, [64] = KEY_F7, [65] = KEY_F8,
	[66] = KEY_F9, [67] = KEY_F10, [68] = KEY_F11, [69] = KEY_F12,
	[70] = KEY_SYSRQ, [71] = KEY_SCROLLLOCK, [72] = KEY_PAUSE,
	[73] = KEY_INSERT, [74] = KEY_HOME, [75] = KEY_PAGEUP,
	[76] = KEY_DELETE, [77] = KEY_END, [78] = KEY_PAGEDOWN,
	[79] = KEY_RIGHT, [80] = KEY_LEFT, [81] = KEY_DOWN,
	[82] = KEY_UP, [83] = KEY_NUMLOCK,
	[84] = KEY_KPSLASH, [85] = KEY_KPASTERISK, [86] = KEY_KPMINUS,
	[87] = KEY_KPPLUS, [88] = KEY_KPENTER, [89] = KEY_KP1,
	[90] = KEY_KP2, [91] = KEY_KP3, [92] = KEY_KP4,
	[93] = KEY_KP5, [94] = KEY_KP6, [95] = KEY_KP7,
	[96] = KEY_KP8, [97] = KEY_KP9, [98] = KEY_KP0,
	[99] = KEY_KPDOT,
};

static const unsigned short modifier_keys[8] = {
	KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA,
	KEY_RIGHTCTRL, KEY_RIGHTSHIFT, KEY_RIGHTALT, KEY_RIGHTMETA,
};

static void gorv32_usb_release_all(struct gorv32_usb_hid *hid)
{
	unsigned short code;
	int i;

	code = hid_keys[hid->old_key];
	if (code)
		input_report_key(hid->input, code, 0);
	for (i = 0; i < 8; i++)
		if (hid->old_mod & BIT(i))
			input_report_key(hid->input, modifier_keys[i], 0);
	hid->old_key = 0;
	hid->old_mod = 0;
	input_sync(hid->input);
}

static void gorv32_usb_poll(struct work_struct *work)
{
	struct gorv32_usb_hid *hid =
		container_of(to_delayed_work(work), struct gorv32_usb_hid,
			     poll_work);
	u32 status = readl(hid->base + REG_STATUS) & 0xff;
	bool connected = status & STATUS_CONNECTED;
	u8 key, mod, changed;
	unsigned short old_code, new_code;
	int i;

	if (!connected) {
		if (hid->connected) {
			gorv32_usb_release_all(hid);
			dev_info(hid->input->dev.parent, "keyboard disconnected\n");
		}
		hid->connected = false;
		goto again;
	}
	if (!hid->connected)
		dev_info(hid->input->dev.parent, "keyboard connected\n");
	hid->connected = true;
	if (!(status & STATUS_READY))
		goto again;

	/* KEY read acknowledges the report, so sample modifiers first. */
	mod = readl(hid->base + REG_MOD) & 0xff;
	key = readl(hid->base + REG_KEY) & 0xff;
	changed = mod ^ hid->old_mod;
	for (i = 0; i < 8; i++)
		if (changed & BIT(i))
			input_report_key(hid->input, modifier_keys[i],
					 !!(mod & BIT(i)));

	old_code = hid_keys[hid->old_key];
	new_code = hid_keys[key];
	if (hid->old_key != key) {
		if (old_code)
			input_report_key(hid->input, old_code, 0);
		if (new_code)
			input_report_key(hid->input, new_code, 1);
	}
	hid->old_key = key;
	hid->old_mod = mod;
	input_sync(hid->input);

again:
	schedule_delayed_work(&hid->poll_work, msecs_to_jiffies(hid->poll_ms));
}

static int gorv32_usb_hid_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct gorv32_usb_hid *hid;
	struct input_dev *input;
	unsigned int i;
	int ret;

	hid = devm_kzalloc(dev, sizeof(*hid), GFP_KERNEL);
	if (!hid)
		return -ENOMEM;
	hid->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hid->base))
		return PTR_ERR(hid->base);
	hid->poll_ms = 10;
	of_property_read_u32(dev->of_node, "poll-interval-ms", &hid->poll_ms);
	hid->poll_ms = clamp_val(hid->poll_ms, 5, 100);

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;
	hid->input = input;
	input->name = "System16 FPGA USB HID keyboard";
	input->phys = "system16-usb/input0";
	input->id.bustype = BUS_USB;
	input->dev.parent = dev;
	__set_bit(EV_KEY, input->evbit);
	__set_bit(EV_REP, input->evbit);
	for (i = 0; i < ARRAY_SIZE(hid_keys); i++)
		if (hid_keys[i])
			__set_bit(hid_keys[i], input->keybit);
	for (i = 0; i < ARRAY_SIZE(modifier_keys); i++)
		__set_bit(modifier_keys[i], input->keybit);

	ret = input_register_device(input);
	if (ret)
		return ret;
	platform_set_drvdata(pdev, hid);
	INIT_DELAYED_WORK(&hid->poll_work, gorv32_usb_poll);
	schedule_delayed_work(&hid->poll_work, 0);
	dev_info(dev, "low-speed HID keyboard polling every %u ms\n",
		 hid->poll_ms);
	return 0;
}

static void gorv32_usb_hid_remove(struct platform_device *pdev)
{
	struct gorv32_usb_hid *hid = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&hid->poll_work);
}

static const struct of_device_id gorv32_usb_hid_of_match[] = {
	{ .compatible = "gowin,system16-usb-hid" },
	{ }
};
MODULE_DEVICE_TABLE(of, gorv32_usb_hid_of_match);

static struct platform_driver gorv32_usb_hid_driver = {
	.probe = gorv32_usb_hid_probe,
	.remove = gorv32_usb_hid_remove,
	.driver = {
		.name = "gorv32-usb-hid",
		.of_match_table = gorv32_usb_hid_of_match,
	},
};
module_platform_driver(gorv32_usb_hid_driver);

MODULE_DESCRIPTION("System16 FPGA low-speed USB HID keyboard");
MODULE_LICENSE("GPL");
