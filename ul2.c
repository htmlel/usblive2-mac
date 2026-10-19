/*
 * ul2.c - USB-Live2 capture core.
 *
 * The hardware programming is the Linux cx231xx + cx25840 driver code (see
 * gen/), called in the same order the Linux driver uses:
 *
 *   plug-in : cx231xx_usb_probe -> cx231xx_init_dev -> cx231xx_init_v4l2
 *   app     : VIDIOC_S_STD, VIDIOC_S_FMT, VIDIOC_S_INPUT
 *   open    : cx231xx_v4l2_open
 *   stream  : start_streaming -> cx231xx_init_isoc / cx231xx_init_bulk
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "cx231xx.h"
#include "ul2.h"

#define USBLIVE2_VID 0x2040
#define USBLIVE2_PID 0xc200
#define NUM_FRAME_BUFS 4

struct v4l2_subdev *port_cx25840_probe(struct i2c_client *client);
int port_cx25840_video_status(struct v4l2_subdev *sd, int *present, int *fmt);
int port_isoc_copy(struct cx231xx *dev, struct urb *urb);
int port_bulk_copy(struct cx231xx *dev, struct urb *urb);
extern int kdebug;

static struct cx231xx *g_dev;
static struct usb_device g_udev;
static libusb_context *g_ctx;
static int g_nifs;
static struct i2c_client g_decoder_client;
static struct cx231xx_buffer g_bufs[NUM_FRAME_BUFS];
static struct libusb_transfer *g_xfers[CX231XX_NUM_BUFS];
static int g_pending, g_stopping, g_streaming, g_gone;
static struct urb g_urb;
static struct ul2_config g_cfg;
static ul2_frame_cb g_cb;
static void *g_cb_user;
static struct ul2_stats g_st;
static u64 g_t_start;

/* audio (cx231xx-audio.c equivalent) */
static struct libusb_transfer *g_axfers[CX231XX_AUDIO_BUFS];
static int g_apending, g_audio_on;
static ul2_audio_cb g_acb;
static void *g_acb_user;

/* Called by the upstream parser (buffer_filled) each time a frame is complete */
void vb2_buffer_done(struct vb2_buffer *vb, enum vb2_buffer_state state)
{
	struct cx231xx_buffer *buf = container_of(vb, struct cx231xx_buffer, vb.vb2_buf);
	struct cx231xx *dev = g_dev;

	if (state == VB2_BUF_STATE_DONE) {
		g_st.frames++;
		if (g_cb)
			g_cb(vb->mem, dev->width, dev->height, g_cb_user);
	}
	/* give the buffer straight back to the capture queue */
	list_add_tail(&buf->list, &dev->video_mode.vidq.active);
}

/* ------------------------------------------------------------ streaming */
static int iso_status_to_errno(enum libusb_transfer_status s)
{
	switch (s) {
	case LIBUSB_TRANSFER_COMPLETED: return 0;
	case LIBUSB_TRANSFER_CANCELLED: return -ENOENT;
	case LIBUSB_TRANSFER_STALL:     return -EPIPE;
	case LIBUSB_TRANSFER_OVERFLOW:  return -EOVERFLOW;
	case LIBUSB_TRANSFER_TIMED_OUT: return -ETIME;
	case LIBUSB_TRANSFER_NO_DEVICE: return -ENODEV;
	default:                        return -EPROTO;
	}
}

static void LIBUSB_CALL transfer_cb(struct libusb_transfer *t)
{
	struct cx231xx *dev = g_dev;

	if (t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) {
		g_pending--;
		if (t->status == LIBUSB_TRANSFER_NO_DEVICE)
			g_gone = 1;
		return;
	}

	/* present the libusb transfer to the upstream parser as a kernel URB */
	memset(&g_urb, 0, sizeof g_urb);
	g_urb.context = &dev->video_mode.vidq;
	g_urb.status = iso_status_to_errno(t->status);
	g_urb.transfer_buffer = t->buffer;
	g_st.transfers++;

	if (dev->USE_ISO) {
		int maxpkt = dev->video_mode.isoc_ctl.max_pkt_size;
		g_urb.number_of_packets = t->num_iso_packets;
		for (int i = 0; i < t->num_iso_packets; i++) {
			struct libusb_iso_packet_descriptor *p = &t->iso_packet_desc[i];
			g_urb.iso_frame_desc[i].offset = i * maxpkt;
			g_urb.iso_frame_desc[i].length = maxpkt;
			g_urb.iso_frame_desc[i].actual_length = p->actual_length;
			g_urb.iso_frame_desc[i].status = iso_status_to_errno(p->status);
			g_st.packets++;
			g_st.bytes += p->actual_length;
			if (p->status != LIBUSB_TRANSFER_COMPLETED)
				g_st.packet_errors++;
		}
		port_isoc_copy(dev, &g_urb);
	} else {
		g_urb.actual_length = t->actual_length;
		g_st.packets++;
		g_st.bytes += t->actual_length;
		if (t->actual_length > 4)
			port_bulk_copy(dev, &g_urb);
	}

	if (g_stopping || libusb_submit_transfer(t) < 0)
		g_pending--;
}

/* Same bookkeeping as the top of cx231xx_init_isoc()/cx231xx_init_bulk() */
static void init_dma_queue(struct cx231xx *dev)
{
	struct cx231xx_dmaqueue *dma_q = &dev->video_mode.vidq;

	dma_q->pos = 0;
	dma_q->is_partial_line = 0;
	dma_q->last_sav = 0;
	dma_q->current_field = -1;
	dma_q->field1_done = 0;
	dma_q->lines_per_field = dev->height / 2;
	dma_q->bytes_left_in_line = dev->width << 1;
	dma_q->lines_completed = 0;
	memset(dma_q->partial_buf, 0, sizeof dma_q->partial_buf);
	dev->video_mode.isoc_ctl.buf = NULL;
	dev->video_mode.bulk_ctl.buf = NULL;
}

/* ------------------------------------------------------------ audio
 * Port of cx231xx-audio.c: the ALSA capture_open (alt setting + capture
 * start for Audio) and audio_trigger (cx231xx_init_audio_isoc/_bulk) paths.
 * The URB handler there just copies the packets out as S16_LE stereo. */
static void LIBUSB_CALL audio_cb(struct libusb_transfer *t)
{
	if (t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE) {
		g_apending--;
		return;
	}
	if (g_dev->USE_ISO) {
		int maxpkt = g_dev->adev.max_pkt_size;
		for (int i = 0; i < t->num_iso_packets; i++) {
			int frames = t->iso_packet_desc[i].actual_length / 4;
			if (frames <= 0)
				continue;
			g_st.audio_frames += frames;
			if (g_acb)
				g_acb((const int16_t *)(t->buffer + i * maxpkt), frames, g_acb_user);
		}
	} else if (t->actual_length >= 4) {
		g_st.audio_frames += t->actual_length / 4;
		if (g_acb)
			g_acb((const int16_t *)t->buffer, t->actual_length / 4, g_acb_user);
	}
	if (g_stopping || libusb_submit_transfer(t) < 0)
		g_apending--;
}

static int audio_start(struct cx231xx *dev)
{
	int npkts = dev->USE_ISO ? CX231XX_ISO_NUM_AUDIO_PACKETS : CX231XX_NUM_AUDIO_PACKETS;
	int r, sb_size;

	if (!dev->adev.alt_max_pkt_size)
		return -ENODEV;
	/* snd_cx231xx_capture_open() */
	r = cx231xx_set_alt_setting(dev, INDEX_AUDIO, dev->USE_ISO ? 1 : 0);
	if (r < 0)
		return r;
	if (!dev->USE_ISO)
		dev->adev.max_pkt_size = dev->adev.alt_max_pkt_size[0];
	r = cx231xx_capture_start(dev, 1, Audio);
	if (r < 0)
		return r;

	/* audio_trigger() -> cx231xx_init_audio_isoc() / cx231xx_init_audio_bulk() */
	sb_size = npkts * dev->adev.max_pkt_size;
	for (int i = 0; i < CX231XX_AUDIO_BUFS; i++) {
		unsigned char *mem = malloc(sb_size);
		g_axfers[i] = libusb_alloc_transfer(dev->USE_ISO ? npkts : 0);
		if (!mem || !g_axfers[i])
			return -ENOMEM;
		memset(mem, 0x80, sb_size);
		if (dev->USE_ISO) {
			libusb_fill_iso_transfer(g_axfers[i], g_udev.h, dev->adev.end_point_addr, mem,
						 sb_size, npkts, audio_cb, NULL, 1000);
			libusb_set_iso_packet_lengths(g_axfers[i], dev->adev.max_pkt_size);
		} else {
			libusb_fill_bulk_transfer(g_axfers[i], g_udev.h, dev->adev.end_point_addr, mem,
						  sb_size, audio_cb, NULL, 1000);
		}
		g_axfers[i]->flags = LIBUSB_TRANSFER_FREE_BUFFER;
		if ((r = libusb_submit_transfer(g_axfers[i])) < 0) {
			fprintf(stderr, "audio transfer submit failed: %s\n", libusb_error_name(r));
			return -EIO;
		}
		g_apending++;
	}
	g_audio_on = 1;
	return 0;
}

static void audio_stop(struct cx231xx *dev)
{
	if (!g_gone)
		cx231xx_capture_start(dev, 0, Audio);
	for (int i = 0; i < CX231XX_AUDIO_BUFS; i++)
		if (g_axfers[i])
			libusb_cancel_transfer(g_axfers[i]);
	for (int tries = 0; g_apending > 0 && tries < 50; tries++) {
		struct timeval tv = { 0, 100000 };
		libusb_handle_events_timeout_completed(g_ctx, &tv, NULL);
	}
	for (int i = 0; i < CX231XX_AUDIO_BUFS; i++) {
		if (g_axfers[i] && g_apending == 0)
			libusb_free_transfer(g_axfers[i]);
		g_axfers[i] = NULL;
	}
	if (!g_gone)
		cx231xx_set_alt_setting(dev, INDEX_AUDIO, 0);
	g_audio_on = 0;
}

void ul2_set_audio_cb(ul2_audio_cb cb, void *user)
{
	g_acb = cb;
	g_acb_user = user;
}

int ul2_start(void)
{
	struct cx231xx *dev = g_dev;
	const int nbufs = CX231XX_NUM_BUFS, npkts = CX231XX_NUM_PACKETS;
	int maxpkt = dev->video_mode.max_pkt_size;
	int sb_size = npkts * maxpkt;
	int r;

	init_dma_queue(dev);
	if (dev->USE_ISO)
		dev->video_mode.isoc_ctl.max_pkt_size = maxpkt;
	else
		dev->video_mode.bulk_ctl.max_pkt_size = maxpkt;
	dev->video_mode.end_point_addr = 0x84;
	g_stopping = 0;
	memset(&g_st, 0, sizeof g_st);

	if (!g_cfg.quiet)
		printf("Streaming %s from endpoint 0x84: %d transfers x %d bytes\n",
		       dev->USE_ISO ? "isochronous" : "bulk", nbufs, sb_size);

	for (int i = 0; i < nbufs; i++) {
		unsigned char *mem = calloc(1, sb_size);
		g_xfers[i] = libusb_alloc_transfer(dev->USE_ISO ? npkts : 0);
		if (!mem || !g_xfers[i])
			return -ENOMEM;
		if (dev->USE_ISO) {
			libusb_fill_iso_transfer(g_xfers[i], g_udev.h, 0x84, mem, sb_size,
						 npkts, transfer_cb, NULL, 1000);
			libusb_set_iso_packet_lengths(g_xfers[i], maxpkt);
		} else {
			libusb_fill_bulk_transfer(g_xfers[i], g_udev.h, 0x84, mem, sb_size,
						  transfer_cb, NULL, 1000);
		}
		g_xfers[i]->flags = LIBUSB_TRANSFER_FREE_BUFFER;
		r = libusb_submit_transfer(g_xfers[i]);
		if (r < 0) {
			fprintf(stderr, "submit of transfer %d failed: %s\n", i, libusb_error_name(r));
			ul2_stop();
			return -EIO;
		}
		g_pending++;
	}

	/* as in cx231xx_init_isoc(): start the chip after the URBs are queued */
	r = cx231xx_capture_start(dev, 1, Raw_Video);
	if (r < 0) {
		fprintf(stderr, "cx231xx_capture_start failed: %d\n", r);
		ul2_stop();
		return r;
	}
	call_all(dev, video, s_stream, 1);
	g_streaming = 1;
	g_t_start = ktime_get_ns();

	if (!g_cfg.no_audio) {
		r = audio_start(dev);
		if (r < 0)
			fprintf(stderr, "audio could not be started (%d); continuing with video only\n", r);
		else if (!g_cfg.quiet)
			printf("Audio: 48 kHz stereo from endpoint 0x%02x (%d-byte packets)\n",
			       dev->adev.end_point_addr, dev->adev.max_pkt_size);
	}
	return 0;
}

int ul2_poll(int timeout_ms)
{
	struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };

	libusb_handle_events_timeout_completed(g_ctx, &tv, NULL);
	if (g_gone || (g_streaming && !g_stopping && g_pending == 0))
		return -ENODEV;
	return 0;
}

/* stop: capture off, cancel transfers, back to alt 0 (stop_streaming/close) */
void ul2_stop(void)
{
	struct cx231xx *dev = g_dev;

	if (!dev)
		return;
	g_stopping = 1;
	if (g_audio_on)
		audio_stop(dev);
	if (!g_gone)
		cx231xx_capture_start(dev, 0, Raw_Video);
	for (int i = 0; i < CX231XX_NUM_BUFS; i++)
		if (g_xfers[i])
			libusb_cancel_transfer(g_xfers[i]);
	for (int tries = 0; g_pending > 0 && tries < 50; tries++) {
		struct timeval tv = { 0, 100000 };
		libusb_handle_events_timeout_completed(g_ctx, &tv, NULL);
	}
	for (int i = 0; i < CX231XX_NUM_BUFS; i++) {
		if (g_xfers[i] && g_pending == 0)
			libusb_free_transfer(g_xfers[i]);
		g_xfers[i] = NULL;
	}
	if (!g_gone)
		cx231xx_set_alt_setting(dev, INDEX_VIDEO, 0);
	g_streaming = 0;
}

/* ------------------------------------------------------------ bring-up */
#define STEP(name, call) do { int _r = (call); \
	if (!g_cfg.quiet || _r < 0) printf("  %-46s %s\n", name, _r < 0 ? "FAILED" : "ok"); \
	if (_r < 0) { fprintf(stderr, "%s returned %d\n", name, _r); return _r; } } while (0)
#define STEPV(name, call) do { call; if (!g_cfg.quiet) printf("  %-46s ok\n", name); } while (0)

/* cx231xx_init_v4l2(): record each video alt setting's max packet size */
static int compute_video_alt_sizes(struct cx231xx *dev, libusb_device *udev)
{
	struct libusb_config_descriptor *cfg;
	int idx = dev->current_pcb_config.hs_config_info[0].interface_info.video_index + 1;
	const struct libusb_interface *itf;

	if (libusb_get_active_config_descriptor(udev, &cfg) != 0)
		return -EIO;
	if (idx >= cfg->bNumInterfaces) {
		libusb_free_config_descriptor(cfg);
		return -ENODEV;
	}
	itf = &cfg->interface[idx];
	dev->video_mode.num_alt = itf->num_altsetting;
	dev->video_mode.alt_max_pkt_size = calloc(itf->num_altsetting, sizeof(unsigned int));
	for (int i = 0; i < itf->num_altsetting; i++) {
		u16 tmp = itf->altsetting[i].endpoint[0].wMaxPacketSize;
		dev->video_mode.alt_max_pkt_size[i] = (tmp & 0x07ff) * (((tmp & 0x1800) >> 11) + 1);
	}
	dev->video_mode.end_point_addr = itf->altsetting[0].endpoint[0].bEndpointAddress;
	libusb_free_config_descriptor(cfg);
	return 0;
}

/* cx231xx_audio_init(): record the audio endpoint and its alt packet sizes */
static int compute_audio_alt_sizes(struct cx231xx *dev, libusb_device *udev)
{
	struct libusb_config_descriptor *cfg;
	int idx = dev->current_pcb_config.hs_config_info[0].interface_info.audio_index + 1;
	const struct libusb_interface *itf;

	if (libusb_get_active_config_descriptor(udev, &cfg) != 0)
		return -EIO;
	if (idx >= cfg->bNumInterfaces) {
		libusb_free_config_descriptor(cfg);
		return -ENODEV;
	}
	itf = &cfg->interface[idx];
	dev->adev.end_point_addr = itf->altsetting[0].endpoint[0].bEndpointAddress;
	dev->adev.num_alt = itf->num_altsetting;
	dev->adev.alt_max_pkt_size = calloc(itf->num_altsetting, sizeof(unsigned int));
	for (int i = 0; i < itf->num_altsetting; i++) {
		u16 tmp = itf->altsetting[i].endpoint[0].wMaxPacketSize;
		dev->adev.alt_max_pkt_size[i] = (tmp & 0x07ff) * (((tmp & 0x1800) >> 11) + 1);
	}
	libusb_free_config_descriptor(cfg);
	return 0;
}

static int bring_up(struct cx231xx *dev, libusb_device *udev)
{
	struct v4l2_subdev_format format = { .which = V4L2_SUBDEV_FORMAT_ACTIVE };
	int input = g_cfg.input == UL2_INPUT_SVIDEO ? 1 : 0;
	v4l2_std_id norm = g_cfg.pal ? V4L2_STD_PAL : V4L2_STD_NTSC_M;
	int present = 0, fmt = 0;

	if (!g_cfg.quiet)
		printf("Initializing (same sequence as the Linux driver):\n");

	/* ---- cx231xx_init_dev() ---- */
	STEP("initialize_cx231xx (read PCB config)", initialize_cx231xx(dev));
	/* (the USB-Live2 "set alt 3" workaround that follows here upstream is a
	 * no-op at this point, because packet sizes are not known yet) */
	STEPV("cx231xx_pre_card_setup", cx231xx_pre_card_setup(dev));
	STEP("cx231xx_dev_init (power, AFE, DIF, I2S)", cx231xx_dev_init(dev));

	/* cx231xx_card_setup(): attach the built-in cx25840-style decoder */
	dev->board = cx231xx_boards[dev->model];
	dev->tuner_type = dev->board.tuner_type;
	g_decoder_client.addr = 0x88 >> 1;
	g_decoder_client.adapter = cx231xx_get_i2c_adap(dev, I2C_0);
	dev->sd_cx25840 = port_cx25840_probe(&g_decoder_client);
	if (!dev->sd_cx25840) {
		fprintf(stderr, "decoder not found on I2C\n");
		return -ENODEV;
	}
	STEP("cx25840 load_fw (decoder initialize)", cx25840_call(dev, core, load_fw));
	STEPV("cx231xx_config_i2c", cx231xx_config_i2c(dev));

	/* cx231xx_register_analog_devices() */
	dev->norm = V4L2_STD_PAL;
	dev->width = 720;
	dev->height = 576;
	dev->video_input = 0;
	STEPV("video_mux(0)", video_mux(dev, dev->video_input));
	STEP("s_std (driver default PAL)", call_all(dev, video, s_std, dev->norm));

	/* cx231xx_init_v4l2() */
	STEP("read video alt settings", compute_video_alt_sizes(dev, udev));
	STEP("read audio alt settings", compute_audio_alt_sizes(dev, udev));

	/* ---- what a capture app does: VIDIOC_S_STD / S_FMT / S_INPUT ---- */
	dev->norm = norm;
	dev->width = 720;
	dev->height = (dev->norm & V4L2_STD_625_50) ? 576 : 480;
	STEP(g_cfg.pal ? "s_std PAL" : "s_std NTSC", call_all(dev, video, s_std, dev->norm));
	format.format.code = MEDIA_BUS_FMT_FIXED;
	format.format.width = dev->width;
	format.format.height = dev->height;
	STEP("set_fmt", call_all(dev, pad, set_fmt, NULL, &format));
	STEP("cx231xx_do_mode_ctrl_overrides", cx231xx_do_mode_ctrl_overrides(dev));
	dev->mode_tv = 0;
	STEPV(input ? "select input: S-Video" : "select input: composite", video_mux(dev, input));

	/* ---- cx231xx_v4l2_open() ---- */
	STEP("set_power_mode (external A/V)", cx231xx_set_power_mode(dev, POLARIS_AVMODE_ENXTERNAL_AV));
	STEP("set_video_alternate", cx231xx_set_video_alternate(dev));
	/* bulk mode stays on alt 0, which upstream never records a size for */
	if (!dev->USE_ISO && dev->video_mode.max_pkt_size == 0)
		dev->video_mode.max_pkt_size = dev->video_mode.alt_max_pkt_size[0];
	if (!g_cfg.quiet)
		printf("    video alt %d, max packet %d bytes\n", dev->video_mode.alt,
		       dev->video_mode.max_pkt_size);
	STEPV("cx231xx_config_i2c", cx231xx_config_i2c(dev));

	/* queue_setup() */
	dev->size = dev->width * dev->height * 2;

	msleep(300);
	port_cx25840_video_status(dev->sd_cx25840, &present, &fmt);
	if (!g_cfg.quiet)
		printf("Decoder status: video signal %s, detected format code %d (%s)\n",
		       present ? "PRESENT" : "not present", fmt,
		       fmt == 1 ? "NTSC-M" : fmt == 4 ? "PAL" : fmt == 0 ? "none" : "other");
	return 0;
}

int ul2_open(const struct ul2_config *cfg, ul2_frame_cb cb, void *user)
{
	libusb_device_handle *h;
	struct libusb_config_descriptor *cdesc;
	struct cx231xx *dev;
	int r;

	g_cfg = *cfg;
	g_cb = cb;
	g_cb_user = user;
	kdebug = cfg->verbose;
	g_gone = g_streaming = g_pending = 0;

	if ((r = libusb_init(&g_ctx)) < 0) {
		fprintf(stderr, "libusb_init: %s\n", libusb_error_name(r));
		return -EIO;
	}
	h = libusb_open_device_with_vid_pid(g_ctx, USBLIVE2_VID, USBLIVE2_PID);
	if (!h) {
		fprintf(stderr, "USB-Live2 (2040:c200) not found or could not be opened.\n");
		libusb_exit(g_ctx);
		g_ctx = NULL;
		return -ENODEV;
	}
	g_udev.h = h;
	g_udev.speed = libusb_get_device_speed(libusb_get_device(h)) == LIBUSB_SPEED_HIGH
		       ? USB_SPEED_HIGH : USB_SPEED_FULL;
	if (g_udev.speed != USB_SPEED_HIGH)
		fprintf(stderr, "warning: not connected at USB 2.0 high speed\n");

	g_nifs = 0;
	if (libusb_get_active_config_descriptor(libusb_get_device(h), &cdesc) == 0) {
		g_nifs = cdesc->bNumInterfaces;
		libusb_free_config_descriptor(cdesc);
	}
	for (int i = 0; i < g_nifs; i++) {
		libusb_detach_kernel_driver(h, i);
		if ((r = libusb_claim_interface(h, i)) < 0)
			fprintf(stderr, "warning: claim interface %d: %s\n", i, libusb_error_name(r));
	}

	/* the parts of cx231xx_usb_probe()/cx231xx_init_dev() that set up the struct */
	dev = g_dev = calloc(1, sizeof(*dev));
	snprintf(dev->name, sizeof dev->name, "cx231xx #0");
	dev->udev = &g_udev;
	dev->model = CX231XX_BOARD_HAUPPAUGE_USBLIVE2;
	dev->board = cx231xx_boards[dev->model];
	dev->USE_ISO = !cfg->bulk;
	dev->max_iad_interface_count = g_nifs;
	dev->interface_count = g_nifs;
	dev->cx231xx_read_ctrl_reg = cx231xx_read_ctrl_reg;
	dev->cx231xx_write_ctrl_reg = cx231xx_write_ctrl_reg;
	dev->cx231xx_send_usb_command = cx231xx_send_usb_command;
	dev->cx231xx_gpio_i2c_read = cx231xx_gpio_i2c_read;
	dev->cx231xx_gpio_i2c_write = cx231xx_gpio_i2c_write;
	INIT_LIST_HEAD(&dev->video_mode.vidq.active);
	INIT_LIST_HEAD(&dev->vbi_mode.vidq.active);

	if ((r = bring_up(dev, libusb_get_device(h))) < 0) {
		ul2_close();
		return r;
	}
	for (int i = 0; i < NUM_FRAME_BUFS; i++) {
		g_bufs[i].vb.vb2_buf.mem = calloc(1, dev->size);
		g_bufs[i].vb.vb2_buf.index = i;
		list_add_tail(&g_bufs[i].list, &dev->video_mode.vidq.active);
	}
	return 0;
}

void ul2_close(void)
{
	if (g_streaming)
		ul2_stop();
	if (g_udev.h) {
		for (int i = 0; i < g_nifs; i++)
			libusb_release_interface(g_udev.h, i);
		libusb_close(g_udev.h);
		g_udev.h = NULL;
	}
	if (g_ctx)
		libusb_exit(g_ctx);
	g_ctx = NULL;
	for (int i = 0; i < NUM_FRAME_BUFS; i++) {
		free(g_bufs[i].vb.vb2_buf.mem);
		g_bufs[i].vb.vb2_buf.mem = NULL;
	}
	if (g_dev) {
		free(g_dev->video_mode.alt_max_pkt_size);
		free(g_dev->adev.alt_max_pkt_size);
		free(g_dev);
	}
	g_dev = NULL;
}

/* VIDIOC_S_INPUT -> cx231xx_s_input() -> video_mux(). The frame parser
 * resynchronises on the next SAV code by itself. */
int ul2_set_input(int input)
{
	if (!g_dev || input < 0 || input > 1)
		return -EINVAL;
	g_dev->mode_tv = 0;
	video_mux(g_dev, input);
	return 0;
}

int port_cx25840_set_ctrl(struct v4l2_subdev *sd, u32 id, s32 val);

/* the cx25840 s_ctrl handler, as VIDIOC_S_CTRL would call it */
int ul2_set_picture(int brightness, int contrast, int saturation, int hue)
{
	struct v4l2_subdev *sd;

	if (!g_dev || !(sd = g_dev->sd_cx25840))
		return -ENODEV;
	port_cx25840_set_ctrl(sd, V4L2_CID_BRIGHTNESS, clamp(brightness, 0, 255));
	port_cx25840_set_ctrl(sd, V4L2_CID_CONTRAST, clamp(contrast, 0, 127));
	port_cx25840_set_ctrl(sd, V4L2_CID_SATURATION, clamp(saturation, 0, 127));
	port_cx25840_set_ctrl(sd, V4L2_CID_HUE, clamp(hue, -128, 127));
	return 0;
}

int ul2_get_input(void) { return g_dev ? (int)g_dev->video_input : 0; }

int ul2_signal(int *present, int *format)
{
	if (!g_dev || g_gone)
		return -ENODEV;
	return port_cx25840_video_status(g_dev->sd_cx25840, present, format);
}

void ul2_get_stats(struct ul2_stats *s)
{
	*s = g_st;
	s->seconds = g_streaming ? (ktime_get_ns() - g_t_start) / 1e9 : 0;
}

int ul2_width(void) { return g_dev ? g_dev->width : 720; }
int ul2_height(void) { return g_dev ? g_dev->height : 480; }
int ul2_is_pal(void) { return g_dev ? !!(g_dev->norm & V4L2_STD_625_50) : 0; }
