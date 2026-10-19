/*
 * mock_libusb.c - a simulated Hauppauge USB-Live2 behind the libusb API.
 * For testing the port without hardware. It:
 *   - exposes the real device's USB descriptors (as reported on the Mac),
 *   - answers CX23102 register (0x0C/0x0D) and I2C (0x00-0x06) vendor requests
 *     from a register file, with the A/V decoder reporting a CX231xx id,
 *   - streams a synthetic BT.656 picture (colour bars) once capture is started,
 *     split into isochronous packets the way the hardware does.
 * Every control request is logged so the init sequence can be inspected.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <math.h>
#include <libusb.h>

static FILE *trace;
static int alt_setting[8];
static uint8_t regs[0x200];                 /* CX23102 control registers */
static uint8_t i2c_mem[3][128][0x1000];      /* [bus][7-bit addr][subaddr] */
static int capturing;
static struct libusb_device *the_dev = (struct libusb_device *)0x1;
static struct libusb_device_handle *the_handle = (struct libusb_device_handle *)0x2;
static int ctrl_count, i2c_count;

/* ---- picture generator: 525-line NTSC, 2 fields, BT.656 with SAV/EAV ---- */
static uint8_t *stream_buf;
static size_t stream_len, stream_pos;

static void put4(uint8_t **p, uint8_t xy) { (*p)[0] = 0xff; (*p)[1] = 0; (*p)[2] = 0; (*p)[3] = xy; *p += 4; }

static void build_stream(void)
{
	static const uint8_t bars[8][3] = { /* Y, U, V for 75% colour bars */
		{180,128,128},{162,44,142},{131,156,44},{112,72,58},
		{84,184,198},{65,100,212},{35,212,114},{16,128,128} };
	uint8_t *p = stream_buf = malloc(2 * 263 * (4 + 1440));
	for (int field = 1; field <= 2; field++) {
		for (int line = 0; line < 262; line++) {
			int active = line >= 20 && line < 260;   /* 240 active lines */
			uint8_t sav = active ? (field == 1 ? 0x80 : 0xc0) : (field == 1 ? 0xa0 : 0xe0);
			put4(&p, sav);
			for (int x = 0; x < 720; x += 2) {       /* UYVY on the wire */
				int b = x * 8 / 720;
				int y = active ? bars[b][0] : 16;
				*p++ = active ? bars[b][1] : 128;
				*p++ = y;
				*p++ = active ? bars[b][2] : 128;
				*p++ = y;
			}
			/* The CX23102 bridge sends only SAV + 1440 active bytes per line
			 * (no EAV / blanking): the upstream parser restarts its line
			 * counter on any non-active code, so that must be the format. */
		}
	}
	stream_len = p - stream_buf;
}

/* ---- descriptors (copied from the probe output on the user's Mac) ---- */
static struct libusb_endpoint_descriptor ep(uint8_t addr, uint8_t type, uint16_t mps)
{
	struct libusb_endpoint_descriptor e = { 0 };
	e.bLength = 7; e.bDescriptorType = 5; e.bEndpointAddress = addr;
	e.bmAttributes = type; e.wMaxPacketSize = mps;
	return e;
}

static struct libusb_endpoint_descriptor eps[6][5];
static struct libusb_interface_descriptor alts[6][5];
static struct libusb_interface ifs[6];
static struct libusb_config_descriptor cfg;

static void build_descriptors(void)
{
	/* wMaxPacketSize: bits 11-12 = extra transactions per microframe */
	uint16_t video[5] = { 512, 184, 728, (2 << 11) | 964, (1 << 11) | 900 };
	uint16_t audio[3] = { 512, 28, 52 };
	int nalt[6] = { 1, 1, 3, 5, 2, 2 };
	for (int i = 0; i < 6; i++) {
		for (int a = 0; a < nalt[i]; a++) {
			switch (i) {
			case 0: eps[i][a] = ep(0x8e, 3, 32); break;
			case 1: eps[i][a] = ep(0x8f, 3, 8); break;
			case 2: eps[i][a] = ep(0x83, a ? 1 : 2, audio[a]); break;
			case 3: eps[i][a] = ep(0x84, a ? 1 : 2, video[a]); break;
			case 4: eps[i][a] = a ? ep(0x05, 2, 512) : ep(0x85, 2, 512); break;
			case 5: eps[i][a] = ep(0x86, a ? 1 : 2, a ? 576 : 512); break;
			}
			alts[i][a].bInterfaceNumber = i;
			alts[i][a].bAlternateSetting = a;
			alts[i][a].bNumEndpoints = 1;
			alts[i][a].bInterfaceClass = 0xff;
			alts[i][a].endpoint = &eps[i][a];
		}
		ifs[i].altsetting = alts[i];
		ifs[i].num_altsetting = nalt[i];
	}
	cfg.bNumInterfaces = 6;
	cfg.interface = ifs;
}

/* ---- libusb API ---- */
int LIBUSB_CALL libusb_init(libusb_context **ctx)
{
	*ctx = (libusb_context *)0x3;
	trace = fopen(getenv("MOCK_TRACE") ? getenv("MOCK_TRACE") : "/dev/null", "w");
	regs[0x00] = 0xc9; regs[0x01] = 0x01;            /* BOARD_CFG_STAT = 0x1c9 */
	regs[0x1b] = 0x04;                               /* EP_MODE_SET = 0x04000000 */
	i2c_mem[0][0x44][0x100] = 0x32;                  /* decoder device id 0x5A32 */
	i2c_mem[0][0x44][0x101] = 0x5a;
	i2c_mem[0][0x44][0x40d] = 0x01;                  /* detected NTSC-M */
	i2c_mem[0][0x44][0x40e] = 0x20;                  /* video present */
	build_descriptors();
	build_stream();
	return 0;
}
void LIBUSB_CALL libusb_exit(libusb_context *ctx)
{
	(void)ctx;
	fprintf(stderr, "[mock] %d control requests, %d of them I2C\n", ctrl_count, i2c_count);
	if (trace) fclose(trace);
}
libusb_device_handle *LIBUSB_CALL libusb_open_device_with_vid_pid(libusb_context *c, uint16_t v, uint16_t p)
{ (void)c; return (v == 0x2040 && p == 0xc200) ? the_handle : NULL; }
libusb_device *LIBUSB_CALL libusb_get_device(libusb_device_handle *h) { (void)h; return the_dev; }
int LIBUSB_CALL libusb_get_device_speed(libusb_device *d) { (void)d; return LIBUSB_SPEED_HIGH; }
int LIBUSB_CALL libusb_get_active_config_descriptor(libusb_device *d, struct libusb_config_descriptor **c)
{ (void)d; *c = &cfg; return 0; }
void LIBUSB_CALL libusb_free_config_descriptor(struct libusb_config_descriptor *c) { (void)c; }
int LIBUSB_CALL libusb_detach_kernel_driver(libusb_device_handle *h, int i) { (void)h; (void)i; return LIBUSB_ERROR_NOT_SUPPORTED; }
int LIBUSB_CALL libusb_claim_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
int LIBUSB_CALL libusb_release_interface(libusb_device_handle *h, int i) { (void)h; (void)i; return 0; }
void LIBUSB_CALL libusb_close(libusb_device_handle *h) { (void)h; }
const char *LIBUSB_CALL libusb_error_name(int e) { static char b[32]; snprintf(b, 32, "LIBUSB_ERR(%d)", e); return b; }

int LIBUSB_CALL libusb_set_interface_alt_setting(libusb_device_handle *h, int i, int a)
{
	(void)h;
	fprintf(trace, "SET_INTERFACE if=%d alt=%d\n", i, a);
	if (i < 0 || i >= 6 || a >= ifs[i].num_altsetting) return LIBUSB_ERROR_NOT_FOUND;
	alt_setting[i] = a;
	return 0;
}

int LIBUSB_CALL libusb_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t req,
	uint16_t val, uint16_t idx, unsigned char *data, uint16_t len, unsigned int timeout)
{
	int in = rt & 0x80;
	(void)h; (void)timeout;
	ctrl_count++;
	if ((rt & 0x60) != 0x40) return LIBUSB_ERROR_PIPE;

	if (req == 0x0c || req == 0x0d) {                /* SET/GET_REGISTER */
		if (idx + len > sizeof regs) return LIBUSB_ERROR_PIPE;
		if (in) memcpy(data, regs + idx, len); else memcpy(regs + idx, data, len);
	} else if (req <= 0x06) {                         /* I2C master 0..2, +4 = read */
		int bus = req & 3, addr = val >> 9, salen = (val >> 2) & 3;
		uint8_t *mem = i2c_mem[bus][addr & 0x7f];
		i2c_count++;
		if (in) {
			if (salen) memcpy(data, mem + (idx & 0xfff), len);
			else memset(data, 0, len);
		} else {
			if (salen) memcpy(mem + (idx & 0xfff), data, len);
			else if (len >= 2) {                     /* subaddress in the data */
				int sa = (addr == 0x44 && len >= 3) ? (data[0] << 8 | data[1]) : data[0];
				int off = (addr == 0x44 && len >= 3) ? 2 : 1;
				memcpy(mem + (sa & 0xfff), data + off, len - off);
			}
		}
	} else if (req == 0x08 || req == 0x09 || req == 0x0a || req == 0x0b) {
		if (in) memset(data, 0, len);                /* GPIO */
	} else {
		return LIBUSB_ERROR_PIPE;
	}
	fprintf(trace, "%s req=%02x val=%04x idx=%04x len=%u", in ? "IN " : "OUT", req, val, idx, len);
	for (int i = 0; i < len && i < 8; i++) fprintf(trace, " %02x", data[i]);
	fprintf(trace, "\n");
	return len;
}

/* ---- transfers ---- */
#define MAXQ 32
static struct libusb_transfer *queue[MAXQ];
static int nq;

struct libusb_transfer *LIBUSB_CALL libusb_alloc_transfer(int n)
{
	return calloc(1, sizeof(struct libusb_transfer) + n * sizeof(struct libusb_iso_packet_descriptor));
}
void LIBUSB_CALL libusb_free_transfer(struct libusb_transfer *t)
{
	if (t && (t->flags & LIBUSB_TRANSFER_FREE_BUFFER)) free(t->buffer);
	free(t);
}
int LIBUSB_CALL libusb_submit_transfer(struct libusb_transfer *t)
{
	if (nq >= MAXQ) return LIBUSB_ERROR_BUSY;
	if (t->type == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS && alt_setting[3] == 0) return LIBUSB_ERROR_IO;
	queue[nq++] = t;
	return 0;
}
int LIBUSB_CALL libusb_cancel_transfer(struct libusb_transfer *t)
{
	t->status = LIBUSB_TRANSFER_CANCELLED;
	t->user_data = (void *)1;
	return 0;
}

/* 1 kHz test tone, 48 kHz stereo S16LE, as the line-in would deliver it */
static unsigned tone_phase;
static void tone(uint8_t *dst, int frames)
{
	int16_t *p = (int16_t *)dst;
	for (int i = 0; i < frames; i++, tone_phase++) {
		int16_t v = (int16_t)(8000 * sin(2 * M_PI * 1000.0 * tone_phase / 48000.0));
		p[2 * i] = v;
		p[2 * i + 1] = v;
	}
}

static size_t take(uint8_t *dst, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		dst[i] = stream_buf[stream_pos++];
		if (stream_pos == stream_len) stream_pos = 0;
	}
	return n;
}

int LIBUSB_CALL libusb_handle_events_timeout_completed(libusb_context *c, struct timeval *tv, int *done)
{
	(void)c; (void)done; (void)tv;
	/* "capture started" = the video endpoint bit (ENABLE_EP4) set in EP_MODE_SET */
	capturing = regs[0x18] & 0x08;
	usleep(33000);                                   /* one NTSC frame period */
	int n = nq; nq = 0;
	struct libusb_transfer *batch[MAXQ];
	memcpy(batch, queue, n * sizeof *batch);
	for (int k = 0; k < n; k++) {
		struct libusb_transfer *t = batch[k];
		if (t->user_data) { t->status = LIBUSB_TRANSFER_CANCELLED; t->callback(t); continue; }
		t->status = LIBUSB_TRANSFER_COMPLETED;
		if (t->endpoint == 0x83) {             /* audio: 6 frames per microframe */
			int on = (regs[0x18] & 0x04) && (t->type != LIBUSB_TRANSFER_TYPE_ISOCHRONOUS || alt_setting[2]);
			if (t->type == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) {
				for (int i = 0; i < t->num_iso_packets; i++) {
					struct libusb_iso_packet_descriptor *p = &t->iso_packet_desc[i];
					p->actual_length = on ? 24 : 0;
					if (on) tone(t->buffer + i * p->length, 6);
					p->status = LIBUSB_TRANSFER_COMPLETED;
				}
			} else {
				t->actual_length = on ? 1536 : 0;
				if (on) tone(t->buffer, 384);
			}
			t->callback(t);
			continue;
		}
		if (t->type == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) {
			for (int i = 0; i < t->num_iso_packets; i++) {
				struct libusb_iso_packet_descriptor *p = &t->iso_packet_desc[i];
				/* ~1440 bytes per microframe ≈ the real 27 MB/s raw rate */
				size_t want = capturing ? 1440 + (i % 3) * 36 : 0;
				if (want > p->length) want = p->length;
				p->actual_length = take(t->buffer + i * p->length, want);
				p->status = LIBUSB_TRANSFER_COMPLETED;
			}
		} else {
			t->actual_length = capturing ? take(t->buffer, t->length) : 0;
		}
		t->callback(t);
	}
	return 0;
}
