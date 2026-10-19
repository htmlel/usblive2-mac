/*
 * kstubs.h - minimal Linux-kernel API shim so the cx231xx / cx25840 driver
 * code can run unmodified in a normal macOS (or Linux) program on top of
 * libusb. Only what the ported functions actually use is provided.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef KSTUBS_H
#define KSTUBS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>
#include <libusb.h>

/* ---- basic types ---- */
typedef uint8_t u8;   typedef int8_t s8;
typedef uint16_t u16; typedef int16_t s16;
typedef uint32_t u32; typedef int32_t s32;
typedef uint64_t u64; typedef int64_t s64;
typedef uint8_t __u8; typedef uint16_t __u16; typedef uint32_t __u32; typedef uint64_t __u64;
typedef uint16_t __le16; typedef uint32_t __le32;
#define __iomem
#define __user
#define __init
#define __exit
#define __force

#include "linux/v4l2_std.h"

/* ---- logging ---- */
extern int kdebug;        /* 0 = quiet, 1 = info, 2 = every register access */
#define KERN_ERR ""
#define KERN_INFO ""
#define KERN_DEBUG ""
#define KERN_WARNING ""
#define KERN_CONT ""
#define printk(fmt, ...) do { if (kdebug >= 2) fprintf(stderr, fmt, ##__VA_ARGS__); } while (0)
#define dev_err(d, fmt, ...)  fprintf(stderr, "[cx231xx] ERROR: " fmt, ##__VA_ARGS__)
#define dev_warn(d, fmt, ...) fprintf(stderr, "[cx231xx] warning: " fmt, ##__VA_ARGS__)
#define dev_info(d, fmt, ...) do { if (kdebug >= 1) fprintf(stderr, "[cx231xx] " fmt, ##__VA_ARGS__); } while (0)
#define dev_dbg(d, fmt, ...)  do { if (kdebug >= 2) fprintf(stderr, "[cx231xx] " fmt, ##__VA_ARGS__); } while (0)
#define pr_err(fmt, ...)  fprintf(stderr, "[cx231xx] ERROR: " fmt, ##__VA_ARGS__)
#define pr_info(fmt, ...) do { if (kdebug >= 1) fprintf(stderr, "[cx231xx] " fmt, ##__VA_ARGS__); } while (0)
#define pr_debug(fmt, ...) do { if (kdebug >= 2) fprintf(stderr, "[cx231xx] " fmt, ##__VA_ARGS__); } while (0)
#define v4l_dbg(lvl, dbg, client, fmt, ...) do { if (kdebug >= 2) fprintf(stderr, "[cx25840] " fmt, ##__VA_ARGS__); } while (0)
#define v4l_err(client, fmt, ...)  fprintf(stderr, "[cx25840] ERROR: " fmt, ##__VA_ARGS__)
#define v4l_info(client, fmt, ...) do { if (kdebug >= 1) fprintf(stderr, "[cx25840] " fmt, ##__VA_ARGS__); } while (0)
/* per-file debug macros from the upstream .c files */
#define cx231xx_coredbg(fmt, ...)  do { if (kdebug >= 2) fprintf(stderr, "[core] " fmt, ##__VA_ARGS__); } while (0)
#define cx231xx_isocdbg(fmt, ...)  do { if (kdebug >= 3) fprintf(stderr, "[isoc] " fmt, ##__VA_ARGS__); } while (0)
#define cx231xx_videodbg(fmt, ...) do { if (kdebug >= 2) fprintf(stderr, "[video] " fmt, ##__VA_ARGS__); } while (0)
#define dprintk1(lvl, fmt, ...)    do { if (kdebug >= 3) fprintf(stderr, "[i2c] " fmt, ##__VA_ARGS__); } while (0)
#define dprintk2(lvl, fmt, ...)    do { if (kdebug >= 3) fprintf(stderr, "[i2c] " fmt, ##__VA_ARGS__); } while (0)
static const int reg_debug = 0, i2c_debug = 0, cx25840_debug = 0;
#define WARN_ON(x) (x)

/* ---- misc kernel helpers ---- */
#define EXPORT_SYMBOL_GPL(x)
#define EXPORT_SYMBOL(x)
#define module_param(a, b, c)
#define MODULE_PARM_DESC(a, b)
#define likely(x) (x)
#define unlikely(x) (x)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define BIT(n) (1UL << (n))
#ifndef offsetof
#define offsetof(t, m) __builtin_offsetof(t, m)
#endif
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define max_t(t, a, b) ((t)(a) > (t)(b) ? (t)(a) : (t)(b))
#define clamp(v, lo, hi) ((v) < (lo) ? (lo) : (v) > (hi) ? (hi) : (v))
#define le32_to_cpu(x) (x)
#define le16_to_cpu(x) (x)
#define cpu_to_le32(x) (x)
#define cpu_to_le16(x) (x)
/* kernel do_div(): divide a u64 in place, return the remainder */
#define do_div(n, base) ({ u32 __b = (base); u32 __r = (u32)((n) % __b); (n) = (n) / __b; __r; })
#define HZ 1000                   /* so jiffies timeouts become milliseconds */
#define GFP_KERNEL 0
#define kzalloc(sz, f) calloc(1, (sz))
#define kfree(p) free(p)
static inline void msleep(unsigned int ms) { usleep(ms * 1000); }
static inline void usleep_range(unsigned long lo, unsigned long hi) { (void)hi; usleep(lo); }
static inline void udelay(unsigned long us) { usleep(us); }
static inline void mdelay(unsigned long ms) { usleep(ms * 1000); }

/* ---- locking: the port is single threaded, so these are no-ops ---- */
struct mutex { int unused; };
typedef struct { int unused; } spinlock_t;
typedef struct { int unused; } wait_queue_head_t;
typedef struct { int counter; } atomic_t;
struct work_struct { int unused; };
struct list_head { struct list_head *next, *prev; };
#define INIT_LIST_HEAD(l) ((l)->next = (l)->prev = (l))
static inline int list_empty(const struct list_head *h) { return h->next == h; }
static inline void list_add_tail(struct list_head *n, struct list_head *h)
{ n->prev = h->prev; n->next = h; h->prev->next = n; h->prev = n; }
#define list_entry(ptr, type, member) container_of(ptr, type, member)
static inline void list_del(struct list_head *e)
{ e->prev->next = e->next; e->next->prev = e->prev; e->next = e->prev = NULL; }
#define mutex_lock(m) ((void)0)
#define mutex_unlock(m) ((void)0)
#define mutex_init(m) ((void)0)

/* ---- opaque kernel / v4l2 objects referenced only by pointer or embedded ---- */
struct device { int unused; };
struct video_device { int unused; };
struct v4l2_device { int unused; };
struct v4l2_ctrl_handler { int error; };
struct cx2341x_handler { int unused; };
struct vb2_queue { int unused; };
/* video buffers: the app owns the memory; vb2_buffer_done() is the app hook */
struct vb2_buffer { void *mem; unsigned int index; u64 timestamp; unsigned long payload; };
struct vb2_v4l2_buffer { struct vb2_buffer vb2_buf; u32 sequence; u32 field; };
enum vb2_buffer_state { VB2_BUF_STATE_DONE, VB2_BUF_STATE_ERROR, VB2_BUF_STATE_QUEUED };
static inline void *vb2_plane_vaddr(struct vb2_buffer *vb, unsigned int p) { (void)p; return vb->mem; }
static inline void vb2_set_plane_payload(struct vb2_buffer *vb, unsigned int p, unsigned long sz)
{ (void)p; vb->payload = sz; }
void vb2_buffer_done(struct vb2_buffer *vb, enum vb2_buffer_state state);
u64 ktime_get_ns(void);

/* a USB request block, filled in from a libusb transfer by the glue code */
struct usb_iso_packet_descriptor { unsigned int offset, length, actual_length; int status; };
#define PORT_MAX_ISO_PACKETS 64
struct urb {
	void *context;
	int status;
	void *transfer_buffer;
	u32 actual_length;
	int number_of_packets;
	struct usb_iso_packet_descriptor iso_frame_desc[PORT_MAX_ISO_PACKETS];
};
struct IR_i2c_init_data { int unused; };
struct i2c_mux_core;
struct snd_pcm_substream;
struct snd_card;
struct rc_map;
struct media_device;
struct cx231xx_dvb;
struct file; struct v4l2_capability; struct v4l2_tuner; struct v4l2_frequency;
struct v4l2_input; struct v4l2_dbg_chip_info; struct v4l2_dbg_register;

/* ---- USB, implemented in glue.c on top of libusb ---- */
struct usb_device { libusb_device_handle *h; int speed; };
struct usb_device_id { int unused; };
#define USB_SPEED_FULL 2
#define USB_SPEED_HIGH 3
#define USB_DIR_IN 0x80
#define USB_DIR_OUT 0x00
#define USB_TYPE_VENDOR 0x40
#define USB_RECIP_DEVICE 0x00
#define usb_rcvctrlpipe(udev, ep) 0x80u
#define usb_sndctrlpipe(udev, ep) 0x00u
int usb_control_msg(struct usb_device *udev, unsigned int pipe, u8 request,
		    u8 requesttype, u16 value, u16 index, void *data,
		    u16 size, int timeout);
int usb_set_interface(struct usb_device *udev, int ifnum, int alt);

/* ---- I2C, routed through the cx231xx I2C masters (glue.c) ---- */
#define I2C_M_RD 0x0001
struct i2c_msg { u16 addr; u16 flags; u16 len; u8 *buf; };
struct i2c_adapter { void *algo_data; char name[48]; };
struct i2c_client { unsigned short addr; struct i2c_adapter *adapter; void *clientdata; };
static inline void *i2c_get_clientdata(const struct i2c_client *c) { return c->clientdata; }
int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
int i2c_master_send(const struct i2c_client *client, const char *buf, int count);

/* ---- v4l2 bits used by the cx25840 decoder code ---- */
struct v4l2_subdev { struct i2c_client *client; };
struct v4l2_subdev_format;
/* v4l2 subdevice calls go straight to the ported cx25840 functions (glue) */
#define v4l2_subdev_call(sd, o, f, ...) subdev_##o##_##f(sd, ##__VA_ARGS__)
#define v4l2_device_call_until_err(v4l2dev, grp, o, f, ...) \
	subdev_##o##_##f(port_v4l2dev_to_sd(v4l2dev), ##__VA_ARGS__)
struct v4l2_device;
struct v4l2_subdev *port_v4l2dev_to_sd(struct v4l2_device *v4l2dev);
int subdev_video_s_routing(struct v4l2_subdev *sd, u32 input, u32 output, u32 config);
int subdev_video_s_std(struct v4l2_subdev *sd, u64 std);
int subdev_video_s_stream(struct v4l2_subdev *sd, int enable);
int subdev_pad_set_fmt(struct v4l2_subdev *sd, void *state, struct v4l2_subdev_format *fmt);
int subdev_core_load_fw(struct v4l2_subdev *sd);
static inline struct i2c_client *v4l2_get_subdevdata(struct v4l2_subdev *sd) { return sd->client; }
struct v4l2_ctrl { u32 id; s32 val; struct v4l2_ctrl_handler *handler; };
struct v4l2_mbus_framefmt { u32 width, height, code, field, colorspace; };
struct v4l2_subdev_state;
struct v4l2_subdev_format { u32 which, pad; struct v4l2_mbus_framefmt format; };
#define V4L2_SUBDEV_FORMAT_TRY 0
#define V4L2_SUBDEV_FORMAT_ACTIVE 1
#define MEDIA_BUS_FMT_FIXED 0x0001
#define V4L2_FIELD_INTERLACED 4
#define V4L2_COLORSPACE_SMPTE170M 1
#define V4L2_TUNER_MODE_LANG1 0x0003
#define V4L2_TUNER_RADIO 1
#define V4L2_TUNER_ANALOG_TV 2
#define V4L2_CID_BRIGHTNESS 0x00980900
#define V4L2_CID_CONTRAST   0x00980901
#define V4L2_CID_SATURATION 0x00980902
#define V4L2_CID_HUE        0x00980903

/* tuner type ids (include/media/tuner.h); USB-Live2 has TUNER_ABSENT */
#define TUNER_ABSENT 4
#define TUNER_XC2028 71
#define TUNER_XC5000 76
#define TUNER_NXP_TDA18271 78
#define TUNER_PHILIPS_FQ1236_MK5 (-100)
#define TUNER_PHILIPS_FM1236_MK3 (-101)
#define TUNER_PHILIPS_TDA8290 (-102)
#define TUNER_NXP_TDA18271_2 (-103)
#define TUNER_SI2157 (-104)

#endif
