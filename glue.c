/*
 * glue.c - connects the ported Linux driver code to libusb.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <time.h>
#include "cx231xx.h"

int kdebug = 0;

static int libusb_to_errno(int r)
{
	switch (r) {
	case LIBUSB_ERROR_TIMEOUT:   return -ETIMEDOUT;
	case LIBUSB_ERROR_PIPE:      return -EPIPE;
	case LIBUSB_ERROR_NO_DEVICE: return -ENODEV;
	case LIBUSB_ERROR_BUSY:      return -EBUSY;
	case LIBUSB_ERROR_ACCESS:    return -EACCES;
	case LIBUSB_ERROR_OVERFLOW:  return -EOVERFLOW;
	case LIBUSB_ERROR_NO_MEM:    return -ENOMEM;
	case LIBUSB_ERROR_INVALID_PARAM: return -EINVAL;
	case LIBUSB_ERROR_NOT_FOUND: return -ENOENT;
	default:                     return -EIO;
	}
}

/* usb_control_msg(): same contract as the kernel's (bytes or -errno) */
int usb_control_msg(struct usb_device *udev, unsigned int pipe, u8 request,
		    u8 requesttype, u16 value, u16 index, void *data,
		    u16 size, int timeout)
{
	int r;

	(void)pipe;
	r = libusb_control_transfer(udev->h, requesttype, request, value, index,
				    data, size, (unsigned int)timeout);
	if (kdebug >= 2) {
		fprintf(stderr, "  ctrl %s req=%02x val=%04x idx=%04x len=%u",
			(requesttype & USB_DIR_IN) ? "IN " : "OUT", request, value,
			index, size);
		if (r > 0) {
			fprintf(stderr, " %s", (requesttype & USB_DIR_IN) ? "<" : ">");
			for (int i = 0; i < r && i < 16; i++)
				fprintf(stderr, " %02x", ((u8 *)data)[i]);
		}
		fprintf(stderr, "%s\n", r < 0 ? " FAILED" : "");
	}
	return r < 0 ? libusb_to_errno(r) : r;
}

int usb_set_interface(struct usb_device *udev, int ifnum, int alt)
{
	int r = libusb_set_interface_alt_setting(udev->h, ifnum, alt);

	if (kdebug >= 1)
		fprintf(stderr, "[usb] interface %d -> alt %d%s\n", ifnum, alt,
			r < 0 ? " FAILED" : "");
	return r < 0 ? libusb_to_errno(r) : 0;
}

/* ---- the kernel I2C core, reduced to what cx231xx_dev_init() needs ---- */
int cx231xx_i2c_register(struct cx231xx_i2c *bus)
{
	bus->i2c_adap.algo_data = bus;
	snprintf(bus->i2c_adap.name, sizeof(bus->i2c_adap.name), "%s-%d",
		 bus->dev->name, bus->nr);
	bus->i2c_rc = 0;
	return 0;
}

void cx231xx_i2c_unregister(struct cx231xx_i2c *bus) { (void)bus; }
int cx231xx_i2c_mux_create(struct cx231xx *dev) { (void)dev; return 0; }
int cx231xx_i2c_mux_register(struct cx231xx *dev, int mux_no) { (void)dev; (void)mux_no; return 0; }
void cx231xx_do_i2c_scan(struct cx231xx *dev, int i2c_port) { (void)dev; (void)i2c_port; }

struct i2c_adapter *cx231xx_get_i2c_adap(struct cx231xx *dev, int i2c_port)
{
	if (i2c_port >= I2C_0 && i2c_port <= I2C_2)
		return &dev->i2c_bus[i2c_port].i2c_adap;
	return NULL; /* the I2C_1 mux ports are only used by tuners/demods */
}

struct v4l2_subdev *port_v4l2dev_to_sd(struct v4l2_device *v4l2dev)
{
	return container_of(v4l2dev, struct cx231xx, v4l2_dev)->sd_cx25840;
}

void cx25840_fw_load_hook(struct i2c_client *client)
{
	(void)client; /* see PATCH 1 in tools/gen.py */
}

u64 ktime_get_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (u64)ts.tv_sec * 1000000000ull + (u64)ts.tv_nsec;
}
