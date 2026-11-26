// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * OnAir GT USB HDTV (USB 11ba:1101) ATSC 8VSB driver
 *
 * Cypress FX2 bridge + LGDT3303 demodulator (I2C 0x0e) +
 * LG TDVS-H062F tuner (I2C 0x61). The FX2 command protocol is the
 * cxusb/"Bluebird" one; the differences are TS start command 0x38 and
 * isochronous TS on EP 0x82 in alt setting 6. Boards with a firmware EEPROM
 * boot warm; blank-EEPROM boards get the FX2 firmware uploaded.
 * See docs/protocol.md for the reverse-engineered details.
 *
 * Builds from Linux 4.4 to 7.0, in-tree or out-of-tree. "dvb_usb.h",
 * "lgdt330x.h" and "tuner-simple.h" are kernel-private headers and must be
 * the target kernel's own copies (see Makefile).
 */

#include <linux/module.h>
#include <linux/version.h>
#include <linux/usb.h>
#include <linux/i2c.h>
#include <linux/delay.h>
#include <media/tuner.h>

#include "dvb_usb.h"
#include "lgdt330x.h"
#include "tuner-simple.h"

#define ONAIRGT_FIRMWARE "dvb-usb-onairgt-01.fw"

#define USB_VID_ONAIR		0x11ba
#define USB_PID_ONAIR_GT	0x1101

/* FX2 EP1 commands */
#define CMD_I2C_WRITE		0x08
#define CMD_I2C_READ		0x09
#define CMD_GET_USB_SPEED	0x0b
#define CMD_STREAMING_STOP	0x37
#define CMD_TS_STREAMING_ON	0x38
#define CMD_DIGITAL		0x51
#define CMD_POWER_OFF		0xdc
#define CMD_POWER_ON		0xde

#define I2C_STATUS_OK		0x08

/* EP1 buffers are 64 bytes; EP 0x81 is a 32-byte interrupt EP in alt 1-6 */
#define MAX_CMD_LEN		64
#define MAX_REPLY_LEN		32

#define LGDT3303_I2C_ADDR	0x0e
#define TUNER_I2C_ADDR		0x61

#define FX2_CPUCS		0xe600
#define FX2_FW_CHUNK		0x200

#define ALT_TS_ISOC		6
#define ALT_TS_BULK		0

DVB_DEFINE_MOD_OPT_ADAPTER_NR(adapter_nr);

static int xfer;
module_param(xfer, int, 0444);
MODULE_PARM_DESC(xfer, "TS transfer: 0=isochronous alt 6 like Windows (default), 1=bulk alt 0");

static int clock_flip;
module_param(clock_flip, int, 0444);
MODULE_PARM_DESC(clock_flip, "lgdt330x clock_polarity_flip (0, 1 or 2; default 0)");

static bool win_ts = true;
module_param(win_ts, bool, 0444);
MODULE_PARM_DESC(win_ts, "Apply the Windows driver LGDT3303 tweaks on 8VSB setup: reg 0x87 = (v & 0xf5) | 0x05, reg 0x47 = 0x88 (default 1)");

struct onairgt_state {
	u8 data[MAX_CMD_LEN];	/* USB transfer buffer, keep first */
	bool fw_powered;
	bool disconnecting;
	int ctrl_error;	/* protected by usb_mutex; re-probe to recover */
};

/*
 * Keep both EP1 transfers under usb_mutex. A short reply is not a successful
 * transaction: the old generic helper leaves the rest of the request buffer
 * intact, so it could be mistaken for valid I2C status/data.
 *
 * A failed transfer can leave an unread reply or a stale data toggle in the
 * FX2. Do not issue more commands on this session (including frontend polls);
 * recovery needs a disconnect/re-probe, not an unbounded retry loop.
 */
static int onairgt_ctrl_msg(struct dvb_usb_device *d, u8 cmd,
			    const u8 *wbuf, int wlen, u8 *rbuf, int rlen)
{
	struct onairgt_state *st = d_to_priv(d);
	int ret, actual;

	if (wlen < 0 || wlen > MAX_CMD_LEN - 1 || rlen < 0 ||
	    rlen > MAX_REPLY_LEN || (wlen && !wbuf) || (rlen && !rbuf))
		return -EINVAL;

	if (READ_ONCE(st->disconnecting) ||
	    d->udev->state == USB_STATE_NOTATTACHED)
		return -ENODEV;

	mutex_lock(&d->usb_mutex);
	if (READ_ONCE(st->disconnecting) ||
	    d->udev->state == USB_STATE_NOTATTACHED) {
		ret = -ENODEV;
		goto out;
	}
	if (st->ctrl_error) {
		ret = st->ctrl_error;
		goto out;
	}

	st->data[0] = cmd;
	if (wlen)
		memcpy(&st->data[1], wbuf, wlen);

	ret = usb_bulk_msg(d->udev, usb_sndbulkpipe(d->udev, 0x01),
			   st->data, 1 + wlen, &actual, 2000);
	if (!ret && actual != 1 + wlen)
		ret = -EIO;
	if (ret)
		goto fault;

	if (rlen) {
		/* usb_bulk_msg also handles interrupt endpoints (alt 6 EP 81). */
		ret = usb_bulk_msg(d->udev, usb_rcvbulkpipe(d->udev, 0x81),
				   st->data, rlen, &actual, 2000);
		if (!ret && actual != rlen)
			ret = -EIO;
		if (ret)
			goto fault;
		memcpy(rbuf, st->data, rlen);
	}
	goto out;

fault:
	st->ctrl_error = ret;
	dev_err(&d->udev->dev,
		"EP1 command 0x%02x failed=%d; disconnect/re-probe required\n",
		cmd, ret);
out:
	mutex_unlock(&d->usb_mutex);
	return ret;
}

/* I2C */
static int onairgt_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg msg[],
			    int num)
{
	struct dvb_usb_device *d = i2c_get_adapdata(adap);
	u8 obuf[MAX_CMD_LEN - 1], ibuf[MAX_REPLY_LEN];
	int ret, i;

	if (mutex_lock_interruptible(&d->i2c_mutex) < 0)
		return -EAGAIN;

	for (i = 0; i < num; i++) {
		if (msg[i].flags & I2C_M_RD) {
			/* plain read: 09 00 rlen addr -> status, data */
			if (1 + msg[i].len > sizeof(ibuf)) {
				ret = -EOPNOTSUPP;
				goto unlock;
			}
			obuf[0] = 0;
			obuf[1] = msg[i].len;
			obuf[2] = msg[i].addr;
			ret = onairgt_ctrl_msg(d, CMD_I2C_READ, obuf, 3,
					       ibuf, 1 + msg[i].len);
			if (ret < 0)
				goto unlock;
			if (ibuf[0] != I2C_STATUS_OK) {
				dev_dbg(&d->udev->dev, "i2c read 0x%02x status %02x\n",
					msg[i].addr, ibuf[0]);
				ret = -EREMOTEIO;
				goto unlock;
			}
			memcpy(msg[i].buf, &ibuf[1], msg[i].len);
		} else if (i + 1 < num && (msg[i + 1].flags & I2C_M_RD) &&
			   msg[i].addr == msg[i + 1].addr) {
			/* write then read: 09 wlen rlen addr wdata -> status, data */
			if (3 + msg[i].len > sizeof(obuf) ||
			    1 + msg[i + 1].len > sizeof(ibuf)) {
				ret = -EOPNOTSUPP;
				goto unlock;
			}
			obuf[0] = msg[i].len;
			obuf[1] = msg[i + 1].len;
			obuf[2] = msg[i].addr;
			memcpy(&obuf[3], msg[i].buf, msg[i].len);
			ret = onairgt_ctrl_msg(d, CMD_I2C_READ, obuf,
					       3 + msg[i].len,
					       ibuf, 1 + msg[i + 1].len);
			if (ret < 0)
				goto unlock;
			if (ibuf[0] != I2C_STATUS_OK) {
				dev_dbg(&d->udev->dev, "i2c wr/rd 0x%02x status %02x\n",
					msg[i].addr, ibuf[0]);
				ret = -EREMOTEIO;
				goto unlock;
			}
			memcpy(msg[i + 1].buf, &ibuf[1], msg[i + 1].len);
			i++;
		} else {
			/* write: 08 addr len data -> status */
			if (2 + msg[i].len > sizeof(obuf)) {
				ret = -EOPNOTSUPP;
				goto unlock;
			}
			obuf[0] = msg[i].addr;
			obuf[1] = msg[i].len;
			memcpy(&obuf[2], msg[i].buf, msg[i].len);
			ret = onairgt_ctrl_msg(d, CMD_I2C_WRITE, obuf,
					       2 + msg[i].len, ibuf, 1);
			if (ret < 0)
				goto unlock;
			if (ibuf[0] != I2C_STATUS_OK) {
				dev_dbg(&d->udev->dev, "i2c write 0x%02x status %02x\n",
					msg[i].addr, ibuf[0]);
				ret = -EREMOTEIO;
				goto unlock;
			}
		}
	}
	ret = num;

unlock:
	mutex_unlock(&d->i2c_mutex);
	return ret;
}

static u32 onairgt_i2c_func(struct i2c_adapter *adapter)
{
	return I2C_FUNC_I2C;
}

/*
 * Not const: dvb_usb_device_properties.i2c_algo is a non-const pointer
 * before Linux 6.15. .master_xfer is still accepted in 7.0 (union with .xfer).
 */
static struct i2c_algorithm onairgt_i2c_algo = {
	.master_xfer   = onairgt_i2c_xfer,
	.functionality = onairgt_i2c_func,
};

/* Firmware */
static int onairgt_identify_state(struct dvb_usb_device *d, const char **name)
{
	struct usb_device *udev = d->udev;

	dev_dbg(&udev->dev, "bcdDevice %04x bMaxPower %02x\n",
		le16_to_cpu(udev->descriptor.bcdDevice),
		udev->actconfig->desc.bMaxPower);

	/*
	 * Windows rule: the FX2 boot descriptors report 100 mA (0x32). Boards
	 * that boot the firmware from their EEPROM (I2C 0x51) always come up
	 * warm (500 mA, bcdDevice 0x1205) and never need the firmware file.
	 * The cold upload path is not hardware-verified (C0-EEPROM boards only).
	 */
	if (udev->actconfig->desc.bMaxPower == 0x32)
		return COLD;

	return WARM;
}

static int onairgt_fx2_write(struct usb_device *udev, u16 addr, u8 *buf,
			     u16 len)
{
	int ret;

	ret = usb_control_msg(udev, usb_sndctrlpipe(udev, 0), 0xa0,
			      USB_TYPE_VENDOR | USB_DIR_OUT, addr, 0,
			      buf, len, 5000);
	if (ret < 0)
		return ret;

	return ret == len ? 0 : -EIO;
}

static int onairgt_download_firmware(struct dvb_usb_device *d,
				     const struct firmware *fw)
{
	struct usb_device *udev = d->udev;
	size_t pos, len;
	u8 *buf;
	int ret;

	if (fw->size == 0 || fw->size > 0x4000) {
		dev_err(&udev->dev, "%s: bad firmware size %zu\n",
			KBUILD_MODNAME, fw->size);
		return -EINVAL;
	}

	buf = kmalloc(FX2_FW_CHUNK, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	/* hold the 8051 in reset */
	buf[0] = 1;
	ret = onairgt_fx2_write(udev, FX2_CPUCS, buf, 1);
	if (ret)
		goto err;

	for (pos = 0; pos < fw->size; pos += len) {
		len = min_t(size_t, FX2_FW_CHUNK, fw->size - pos);
		memcpy(buf, fw->data + pos, len);
		ret = onairgt_fx2_write(udev, pos, buf, len);
		if (ret)
			goto err;
	}

	/* release reset; the firmware disconnects and re-enumerates */
	buf[0] = 0;
	ret = onairgt_fx2_write(udev, FX2_CPUCS, buf, 1);
	if (ret)
		goto err;

	kfree(buf);
	return RECONNECTS_USB;
err:
	kfree(buf);
	dev_err(&udev->dev, "%s: firmware download failed=%d\n",
		KBUILD_MODNAME, ret);
	return ret;
}

/*
 * Select the TS alt setting before any command traffic. The firmware does
 * not reset its data toggles on SET_INTERFACE while the host does, so the
 * next EP 0x81 reply would be dropped as a duplicate. CLEAR_FEATURE(HALT)
 * resets them on both sides (the Windows driver resets its pipes here too).
 */
static int onairgt_set_alt(struct dvb_usb_device *d)
{
	struct usb_device *udev = d->udev;
	int alt = xfer ? ALT_TS_BULK : ALT_TS_ISOC;
	int ret;

	ret = usb_set_interface(udev, 0, alt);
	if (!ret)
		ret = usb_clear_halt(udev, usb_sndbulkpipe(udev, 0x01));
	if (!ret)
		ret = usb_clear_halt(udev, usb_rcvbulkpipe(udev, 0x81));
	if (!ret && xfer)
		ret = usb_clear_halt(udev, usb_rcvbulkpipe(udev, 0x82));
	if (ret)
		dev_err(&udev->dev, "%s: selecting alt setting %d failed=%d\n",
			KBUILD_MODNAME, alt, ret);

	return ret;
}

/*
 * Power on once and never power off: 0xde runs the firmware's analog-mode
 * GPIO sequence (demod in reset) and 0xdc cuts the demod, after which
 * lgdt330x would not reprogram its cached 8VSB setup. cxusb Bluebird
 * devices take the same approach.
 */
static int onairgt_power_ctrl(struct dvb_usb_device *d, int onoff)
{
	struct onairgt_state *st = d_to_priv(d);
	u8 b = 0;
	int ret;

	if (!onoff || st->fw_powered)
		return 0;

	ret = onairgt_set_alt(d);
	if (ret)
		return ret;

	ret = onairgt_ctrl_msg(d, CMD_POWER_ON, &b, 1, NULL, 0);
	if (ret)
		return ret;

	ret = onairgt_ctrl_msg(d, CMD_GET_USB_SPEED, NULL, 0, &b, 1);
	if (ret)
		return ret;
	if (!b) {
		dev_err(&d->udev->dev, "%s: device is not running at USB high speed\n",
			KBUILD_MODNAME);
		return -ENODEV;
	}

	st->fw_powered = true;
	return 0;
}

/* Frontend */
static int onairgt_demod_write(struct dvb_usb_device *d, u8 reg, u8 val)
{
	u8 buf[2] = { reg, val };
	struct i2c_msg msg = {
		.addr = LGDT3303_I2C_ADDR, .flags = 0, .buf = buf, .len = 2
	};

	return i2c_transfer(&d->i2c_adap, &msg, 1) == 1 ? 0 : -EREMOTEIO;
}

static int onairgt_demod_read(struct dvb_usb_device *d, u8 reg, u8 *val)
{
	struct i2c_msg msg[2] = {
		{ .addr = LGDT3303_I2C_ADDR, .flags = 0, .buf = &reg, .len = 1 },
		{ .addr = LGDT3303_I2C_ADDR, .flags = I2C_M_RD, .buf = val, .len = 1 },
	};

	return i2c_transfer(&d->i2c_adap, msg, 2) == 2 ? 0 : -EREMOTEIO;
}

/* called by lgdt330x after it programmed a new modulation */
static int onairgt_set_ts_params(struct dvb_frontend *fe, int is_punctured)
{
	struct dvb_usb_device *d = fe_to_d(fe);
	u8 v;
	int ret;

	if (!win_ts || fe->dtv_property_cache.modulation != VSB_8)
		return 0;

	ret = onairgt_demod_write(d, 0x47, 0x88);
	if (ret)
		return ret;

	ret = onairgt_demod_read(d, 0x87, &v);
	if (ret)
		return ret;
	dev_dbg(&d->udev->dev, "lgdt3303 reg 0x87 = %02x -> %02x\n",
		v, (v & 0xf5) | 0x05);

	return onairgt_demod_write(d, 0x87, (v & 0xf5) | 0x05);
}

static struct lgdt330x_config onairgt_lgdt3303_config = {
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)
	.demod_address = LGDT3303_I2C_ADDR,
#endif
	.demod_chip    = LGDT3303,
	.serial_mpeg   = 0x00,	/* parallel TS */
	.set_ts_params = onairgt_set_ts_params,
};

static int onairgt_frontend_attach(struct dvb_usb_adapter *adap)
{
	struct dvb_usb_device *d = adap_to_d(adap);
	struct onairgt_state *st = d_to_priv(d);
	u8 b;
	int ret;

	/* dvb_usbv2_init() ignores the power_ctrl() result */
	if (!st->fw_powered) {
		ret = st->ctrl_error ? st->ctrl_error : -ENODEV;
		dev_err(&d->udev->dev, "FX2 initialization failed=%d\n", ret);
		return ret;
	}

	/* digital mode; the firmware pulses the demod reset (~50 ms) */
	ret = onairgt_ctrl_msg(d, CMD_DIGITAL, NULL, 0, &b, 1);
	if (ret)
		return ret;
	if (b != 0x01)
		dev_warn(&d->udev->dev, "%s: digital mode reply %02x\n",
			 KBUILD_MODNAME, b);
	msleep(20);

	onairgt_lgdt3303_config.clock_polarity_flip = clock_flip;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
	adap->fe[0] = dvb_attach(lgdt330x_attach, &onairgt_lgdt3303_config,
				 LGDT3303_I2C_ADDR, &d->i2c_adap);
#else
	/* the I2C address moved from the config to an argument in 4.18 */
	adap->fe[0] = dvb_attach(lgdt330x_attach, &onairgt_lgdt3303_config,
				 &d->i2c_adap);
#endif
	if (!adap->fe[0])
		return -ENODEV;

	return 0;
}

static int onairgt_tuner_attach(struct dvb_usb_adapter *adap)
{
	struct dvb_usb_device *d = adap_to_d(adap);

	if (!dvb_attach(simple_tuner_attach, adap->fe[0], &d->i2c_adap,
			TUNER_I2C_ADDR, TUNER_LG_TDVS_H06XF))
		return -ENODEV;

	return 0;
}

/* Streaming */
static int onairgt_streaming_ctrl(struct dvb_frontend *fe, int onoff)
{
	struct dvb_usb_device *d = fe_to_d(fe);
	static const u8 on[2] = { 0x03, 0x00 };

	if (onoff)
		return onairgt_ctrl_msg(d, CMD_TS_STREAMING_ON, on, 2, NULL, 0);

	return onairgt_ctrl_msg(d, CMD_STREAMING_STOP, NULL, 0, NULL, 0);
}

static int onairgt_get_stream_config(struct dvb_frontend *fe, u8 *ts_type,
				     struct usb_data_stream_properties *stream)
{
	*ts_type = DVB_USB_FE_TS_TYPE_188;

	if (xfer) {
		/* alt 0: EP 0x82 is bulk 512; fits in the isoc buffers */
		stream->type = USB_BULK;
		stream->count = 8;
		stream->endpoint = 0x82;
		stream->u.bulk.buffersize = 32 * 512;
	}

	return 0;
}

/*
 * Called first by dvb_usbv2_disconnect(), for physical removal AND logical
 * unbind. Reject new control I/O before the framework tears down resources.
 * This is not a replacement for closing DVB file descriptors before unplug.
 */
static void onairgt_exit(struct dvb_usb_device *d)
{
	struct onairgt_state *st = d_to_priv(d);
	int i;

	WRITE_ONCE(st->disconnecting, true);

	for (i = 0; i < MAX_NO_OF_FE_PER_ADAP; i++)
		if (d->adapter[0].fe[i])
			d->adapter[0].fe[i]->exit = DVB_FE_DEVICE_REMOVED;
}

static const struct dvb_usb_device_properties onairgt_props = {
	.driver_name = KBUILD_MODNAME,
	.owner = THIS_MODULE,
	.adapter_nr = adapter_nr,
	.size_of_priv = sizeof(struct onairgt_state),

	.generic_bulk_ctrl_endpoint = 0x01,
	.generic_bulk_ctrl_endpoint_response = 0x81,

	.identify_state = onairgt_identify_state,
	.firmware = ONAIRGT_FIRMWARE,
	.download_firmware = onairgt_download_firmware,

	.i2c_algo = &onairgt_i2c_algo,
	.power_ctrl = onairgt_power_ctrl,
	.frontend_attach = onairgt_frontend_attach,
	.tuner_attach = onairgt_tuner_attach,
	.streaming_ctrl = onairgt_streaming_ctrl,
	.get_stream_config = onairgt_get_stream_config,
	.exit = onairgt_exit,

	.num_adapters = 1,
	.adapter = {
		{
			/* alt 6: iso IN 940 bytes (5 TS packets) per microframe */
			.stream = DVB_USB_STREAM_ISOC(0x82, 8, 32, 940, 1),
		},
	},
};

static const struct usb_device_id onairgt_id_table[] = {
	{ DVB_USB_DEVICE(USB_VID_ONAIR, USB_PID_ONAIR_GT,
		&onairgt_props, "OnAir GT USB HDTV", NULL) },
	{ }
};
MODULE_DEVICE_TABLE(usb, onairgt_id_table);

static struct usb_driver onairgt_usb_driver = {
	.name = KBUILD_MODNAME,
	.id_table = onairgt_id_table,
	.probe = dvb_usbv2_probe,
	.disconnect = dvb_usbv2_disconnect,
	.suspend = dvb_usbv2_suspend,
	.resume = dvb_usbv2_resume,
	.reset_resume = dvb_usbv2_reset_resume,
	.no_dynamic_id = 1,
	.soft_unbind = 1,
};

module_usb_driver(onairgt_usb_driver);

MODULE_DESCRIPTION("OnAir GT USB HDTV ATSC driver");
MODULE_LICENSE("GPL");
MODULE_FIRMWARE(ONAIRGT_FIRMWARE);
