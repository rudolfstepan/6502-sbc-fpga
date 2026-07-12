// SPDX-License-Identifier: GPL-2.0
/*
 * System16 GoRV32 hardware text console.
 *
 * The FPGA presents an 80x22 character-cell grid behind the AXI slave
 * window: a 16-bit cell (low byte = character code, high byte = a
 * VGA-style attribute) at 0xE8000000, and control/cursor registers at
 * 0xE8800000. The cell layout is identical to what the VT layer keeps in
 * its own buffer, so a cell is pushed straight to hardware with a single
 * iowrite16 -- output and scrolling move ~2 bytes per character instead of
 * the hundreds of pixel bytes a graphical framebuffer console rewrites,
 * which is the whole reason this console exists.
 *
 * Rendering (glyph pixels from the on-chip font ROM) and the blinking
 * cursor are done in hardware; this driver only writes cells and moves the
 * cursor register. Input comes from the separate USB-HID keyboard node.
 */
#include <linux/console.h>
#include <linux/vt_kern.h>
#include <linux/vt_buffer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/io.h>

#define S16T_REG_ID     0x00
#define S16T_REG_CTRL   0x04
#define S16T_REG_STATUS 0x08
#define S16T_REG_CURSOR 0x0c
#define S16T_REG_GEOM   0x10
#define S16T_REG_START  0x14

#define S16T_CTRL_ENABLE  0x1   /* bit0: scanout enable (bit1 test, bit2 stripe) */
#define S16T_ID           0x53313654u   /* "S16T" */

static void __iomem *s16t_cells;
static void __iomem *s16t_regs;
static unsigned int  s16t_cols = 80;
static unsigned int  s16t_rows = 22;

static inline void s16t_cell(unsigned int idx, u16 v)
{
	iowrite16(v, s16t_cells + idx * 2);
}

static const char *s16con_startup(void)
{
	return "System16 text console";
}

static void s16con_init(struct vc_data *vc, bool init)
{
	vc->vc_can_do_color = 1;
	vc->vc_complement_mask = 0x7700;
	vc->vc_hi_font_mask = 0;
	if (init) {
		vc->vc_cols = s16t_cols;
		vc->vc_rows = s16t_rows;
	} else {
		vc_resize(vc, s16t_cols, s16t_rows);
	}
}

static void s16con_deinit(struct vc_data *vc)
{
}

static void s16con_clear(struct vc_data *vc, unsigned int y, unsigned int x,
			 unsigned int count)
{
	unsigned int idx = y * s16t_cols + x;

	while (count--)
		s16t_cell(idx++, vc->vc_video_erase_char);
}

static void s16con_putc(struct vc_data *vc, u16 ca, unsigned int y,
			unsigned int x)
{
	s16t_cell(y * s16t_cols + x, ca);
}

static void s16con_putcs(struct vc_data *vc, const u16 *s, unsigned int count,
			 unsigned int y, unsigned int x)
{
	unsigned int idx = y * s16t_cols + x;

	while (count--)
		s16t_cell(idx++, scr_readw(s++));
}

static void s16con_cursor(struct vc_data *vc, bool enable)
{
	u32 v = 0;

	if (enable && vc->vc_mode == KD_TEXT)
		v = (1u << 16) |
		    ((vc->state.y & 0x1f) << 8) |
		    (vc->state.x & 0x7f);
	iowrite32(v, s16t_regs + S16T_REG_CURSOR);
}

static bool s16con_scroll(struct vc_data *vc, unsigned int top,
			  unsigned int bottom, enum con_scroll dir,
			  unsigned int nr)
{
	unsigned int rows = bottom - top;
	unsigned int r, c, idx;
	u16 *clear, *dst, *src, *tmp;

	if (dir != SM_UP && dir != SM_DOWN)
		return false;

	/*
	 * Returning false would only scroll the VT's own shadow buffer and
	 * never touch the hardware (that path is for display-less consoles
	 * like dummycon). So do the shadow-buffer move ourselves -- exactly
	 * as drivers/tty/vt/vt.c con_scroll() would on the false path -- then
	 * mirror the affected rows to the hardware cell array and return true.
	 * The mirror is write-only (iowrite16), no MMIO read-back.
	 */
	src = clear = (u16 *)(vc->vc_origin + vc->vc_size_row * top);
	dst = (u16 *)(vc->vc_origin + vc->vc_size_row * (top + nr));
	if (dir == SM_UP) {
		clear = src + (rows - nr) * vc->vc_cols;
		tmp = src; src = dst; dst = tmp;
	}
	scr_memmovew(dst, src, (rows - nr) * vc->vc_size_row);
	scr_memsetw(clear, vc->vc_video_erase_char, vc->vc_size_row * nr);

	for (r = top; r < bottom; r++) {
		const u16 *p = (const u16 *)(vc->vc_origin +
					     vc->vc_size_row * r);
		idx = r * s16t_cols;
		for (c = 0; c < s16t_cols; c++)
			s16t_cell(idx + c, scr_readw(p + c));
	}
	return true;
}

static bool s16con_switch(struct vc_data *vc)
{
	return true;   /* single console: request a full repaint on switch */
}

static bool s16con_blank(struct vc_data *vc, enum vesa_blank_mode blank,
			 bool mode_switch)
{
	return false;  /* no hardware blanking; VT clears via clear/putcs */
}

static u8 s16con_build_attr(struct vc_data *vc, u8 color,
			    enum vc_intensity intensity, bool blink,
			    bool underline, bool reverse, bool italic)
{
	u8 attr = color;   /* VGA packing: bg high nibble, fg low nibble */

	if (reverse)
		attr = (attr & 0x88) | (((attr >> 4) | (attr << 4)) & 0x77);
	if (intensity == VCI_BOLD)
		attr ^= 0x08;   /* bright foreground */
	return attr;
}

static const struct consw s16_con = {
	.owner		= THIS_MODULE,
	.con_startup	= s16con_startup,
	.con_init	= s16con_init,
	.con_deinit	= s16con_deinit,
	.con_clear	= s16con_clear,
	.con_putc	= s16con_putc,
	.con_putcs	= s16con_putcs,
	.con_cursor	= s16con_cursor,
	.con_scroll	= s16con_scroll,
	.con_switch	= s16con_switch,
	.con_blank	= s16con_blank,
	.con_build_attr	= s16con_build_attr,
};

static int s16con_probe(struct platform_device *pdev)
{
	struct resource *rc, *rr;
	u32 id, geom;
	int ret;

	rc = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	rr = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!rc || !rr)
		return -EINVAL;

	s16t_cells = devm_ioremap(&pdev->dev, rc->start, resource_size(rc));
	s16t_regs  = devm_ioremap(&pdev->dev, rr->start, resource_size(rr));
	if (!s16t_cells || !s16t_regs)
		return -ENOMEM;

	id = ioread32(s16t_regs + S16T_REG_ID);
	if (id != S16T_ID) {
		dev_err(&pdev->dev, "unexpected ID 0x%08x (expected S16T)\n", id);
		return -ENODEV;
	}

	geom = ioread32(s16t_regs + S16T_REG_GEOM);
	if ((geom & 0xff) && ((geom >> 8) & 0xff)) {
		s16t_cols = geom & 0xff;
		s16t_rows = (geom >> 8) & 0xff;
	}

	/* Enable scanout; clear the reset-time test pattern / diag stripe. */
	iowrite32(S16T_CTRL_ENABLE, s16t_regs + S16T_REG_CTRL);

	dev_info(&pdev->dev, "System16 text console %ux%u\n",
		 s16t_cols, s16t_rows);

	ret = do_take_over_console(&s16_con, 0, MAX_NR_CONSOLES - 1, 1);
	if (ret)
		dev_err(&pdev->dev, "do_take_over_console failed: %d\n", ret);
	return ret;
}

static const struct of_device_id s16con_of_match[] = {
	{ .compatible = "gowin,system16-textcon" },
	{ }
};
MODULE_DEVICE_TABLE(of, s16con_of_match);

static struct platform_driver s16con_driver = {
	.probe = s16con_probe,
	.driver = {
		.name = "system16-textcon",
		.of_match_table = s16con_of_match,
	},
};
builtin_platform_driver(s16con_driver);
