/*
 * engine.c - capture thread + picture/audio processing for the Mac app.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "engine.h"
#include "recorder.h"
#include "ul2.h"

#define CROP_X 8          /* 720 -> 704, the standard 4:3 active width */
#define CROP_Y 4          /* trims the half-lines at the top/bottom edges */

/* ---------------------------------------------------------- state */
static pthread_t g_thread;
static int g_thread_live;
static atomic_int g_state, g_quit;
static int g_input_cfg, g_pal;
static eng_video_cb g_cb;
static void *g_ctx;

/* requests from the UI, applied on the capture thread */
static atomic_int req_input = -1;
static atomic_int deint_mode = ENG_DEINT_BLEND, crop_on = 0;
static atomic_int pic_dirty;
static atomic_int pic_b = 128, pic_c = 64, pic_s = 64, pic_h = 0;

/* status published by the capture thread */
static atomic_int st_signal, st_format, st_input, st_out_w = 720, st_out_h = 480;
static _Atomic double st_fps;
static atomic_int st_level;            /* peak * 1000 */

/* processing buffers (capture thread only) */
static uint8_t *g_crop, *g_out, *g_out2;
static size_t g_buf_size;

/* recording */
static pthread_mutex_t rec_lock = PTHREAD_MUTEX_INITIALIZER;
static int rec_w, rec_h;
static struct timespec rec_t0;

/* ---------------------------------------------------------- audio ring
 * Single producer (capture thread) / single consumer (audio render thread),
 * lock-free. Stereo S16 frames. */
#define RING_FRAMES 16384               /* ~340 ms */
#define TARGET_FRAMES 2400              /* aim for ~50 ms of buffered audio */
#define MAX_FRAMES 7200                 /* above ~150 ms, skip ahead */
static int16_t ring[RING_FRAMES * 2];
static atomic_uint_fast64_t ring_w, ring_r;
static int ring_primed;                 /* consumer only */
static int peak_acc;                    /* producer only */

static void ring_reset(void)
{
	atomic_store(&ring_w, 0);
	atomic_store(&ring_r, 0);
	ring_primed = 0;
}

static void ring_write(const int16_t *src, int frames)
{
	uint64_t w = atomic_load_explicit(&ring_w, memory_order_relaxed);
	uint64_t r = atomic_load_explicit(&ring_r, memory_order_acquire);
	uint64_t space = RING_FRAMES - (w - r);

	if ((uint64_t)frames > space)
		frames = (int)space;            /* consumer stalled: drop the excess */
	for (int i = 0; i < frames; i++) {
		size_t k = (size_t)((w + i) % RING_FRAMES) * 2;
		ring[k] = src[2 * i];
		ring[k + 1] = src[2 * i + 1];
	}
	atomic_store_explicit(&ring_w, w + frames, memory_order_release);
}

int eng_audio_read(int16_t *dst, int frames)
{
	uint64_t r = atomic_load_explicit(&ring_r, memory_order_relaxed);
	uint64_t w = atomic_load_explicit(&ring_w, memory_order_acquire);
	uint64_t avail = w - r;
	int n;

	/* wait for a small cushion before starting, so playback doesn't crackle */
	if (!ring_primed) {
		if (avail < TARGET_FRAMES) {
			memset(dst, 0, (size_t)frames * 4);
			return 0;
		}
		ring_primed = 1;
	}
	/* if the device clock runs ahead of the Mac's, drop a little to stay live */
	if (avail > MAX_FRAMES) {
		r = w - TARGET_FRAMES;
		avail = TARGET_FRAMES;
	}
	n = avail < (uint64_t)frames ? (int)avail : frames;
	for (int i = 0; i < n; i++) {
		size_t k = (size_t)((r + i) % RING_FRAMES) * 2;
		dst[2 * i] = ring[k];
		dst[2 * i + 1] = ring[k + 1];
	}
	if (n < frames) {
		memset(dst + 2 * n, 0, (size_t)(frames - n) * 4);
		ring_primed = 0;                /* ran dry: re-prime */
	}
	atomic_store_explicit(&ring_r, r + n, memory_order_release);
	return n;
}

/* ---------------------------------------------------------- picture processing */
static void ensure_buffers(size_t size)
{
	if (size <= g_buf_size)
		return;
	free(g_crop); free(g_out); free(g_out2);
	g_crop = malloc(size);
	g_out = malloc(size);
	g_out2 = malloc(size);
	g_buf_size = size;
}

/* classic linear blend: out[y] = (in[y-1] + 2*in[y] + in[y+1]) / 4 */
static void blend(uint8_t *dst, const uint8_t *src, int w, int h)
{
	int stride = w * 2;
	for (int y = 0; y < h; y++) {
		const uint8_t *a = src + (size_t)(y > 0 ? y - 1 : y) * stride;
		const uint8_t *b = src + (size_t)y * stride;
		const uint8_t *c = src + (size_t)(y < h - 1 ? y + 1 : y) * stride;
		uint8_t *o = dst + (size_t)y * stride;
		for (int x = 0; x < stride; x++)
			o[x] = (uint8_t)((a[x] + 2 * b[x] + c[x] + 2) >> 2);
	}
}

/* "bob": keep one field's lines, interpolate the other field's lines from
 * the lines above and below, giving a full-height picture per field */
static void bob(uint8_t *dst, const uint8_t *src, int w, int h, int field)
{
	int stride = w * 2;
	for (int y = 0; y < h; y++) {
		uint8_t *o = dst + (size_t)y * stride;
		if ((y & 1) == field) {
			memcpy(o, src + (size_t)y * stride, stride);
		} else {
			int ya = y - 1 >= 0 ? y - 1 : y + 1;
			int yb = y + 1 < h ? y + 1 : y - 1;
			const uint8_t *a = src + (size_t)ya * stride;
			const uint8_t *b = src + (size_t)yb * stride;
			for (int x = 0; x < stride; x++)
				o[x] = (uint8_t)((a[x] + b[x] + 1) >> 1);
		}
	}
}

static void on_frame(const uint8_t *yuyv, int w, int h, void *user)
{
	const uint8_t *src = yuyv;
	int mode = atomic_load(&deint_mode);
	double field_time = g_pal ? 1.0 / 50.0 : 1001.0 / 60000.0;

	(void)user;
	ensure_buffers((size_t)w * h * 2);

	if (atomic_load(&crop_on)) {
		int cw = w - 2 * CROP_X, ch = h - 2 * CROP_Y;
		for (int y = 0; y < ch; y++)
			memcpy(g_crop + (size_t)y * cw * 2,
			       yuyv + ((size_t)(y + CROP_Y) * w + CROP_X) * 2, (size_t)cw * 2);
		src = g_crop;
		w = cw;
		h = ch;
	}
	atomic_store(&st_out_w, w);
	atomic_store(&st_out_h, h);

	/* recording gets the (cropped) woven frame; ffmpeg deinterlaces it */
	pthread_mutex_lock(&rec_lock);
	if (rec_active() && w == rec_w && h == rec_h)
		rec_push(src);
	pthread_mutex_unlock(&rec_lock);

	if (!g_cb)
		return;
	switch (mode) {
	case ENG_DEINT_OFF:
		g_cb(src, w, h, 0, g_ctx);
		break;
	case ENG_DEINT_BLEND:
		blend(g_out, src, w, h);
		g_cb(g_out, w, h, 0, g_ctx);
		break;
	default:
		/* field 1 (even rows) arrives first, then field 2 (odd rows) */
		bob(g_out, src, w, h, 0);
		bob(g_out2, src, w, h, 1);
		g_cb(g_out, w, h, 0, g_ctx);
		g_cb(g_out2, w, h, field_time, g_ctx);
		break;
	}
}

static void on_audio(const int16_t *samples, int frames, void *user)
{
	(void)user;
	for (int i = 0; i < frames * 2; i++) {
		int v = samples[i] < 0 ? -samples[i] : samples[i];
		if (v > peak_acc)
			peak_acc = v;
	}
	ring_write(samples, frames);
	rec_push_audio(samples, frames);
}

/* ---------------------------------------------------------- capture thread */
static void *capture_main(void *arg)
{
	struct ul2_config cfg = { 0 };
	struct ul2_stats s;
	double last_status = -1, last_fps_t = 0, last_level_t = 0;
	uint64_t last_frames = 0;

	(void)arg;
	cfg.input = g_input_cfg;
	cfg.pal = g_pal;
	cfg.quiet = 1;
	ring_reset();
	{
		int r = ul2_open(&cfg, on_frame, NULL);
		if (r < 0) {
			atomic_store(&g_state, r == -ENODEV ? ENG_NOT_FOUND : ENG_FAILED);
			return NULL;
		}
	}
	ul2_set_audio_cb(on_audio, NULL);
	if (ul2_start() < 0) {
		ul2_close();
		atomic_store(&g_state, ENG_FAILED);
		return NULL;
	}
	atomic_store(&st_input, ul2_get_input());
	atomic_store(&pic_dirty, 1);
	atomic_store(&g_state, ENG_RUNNING);

	while (!atomic_load(&g_quit)) {
		int in = atomic_exchange(&req_input, -1);
		if (in >= 0) {
			ul2_set_input(in);
			atomic_store(&st_input, ul2_get_input());
		}
		if (atomic_exchange(&pic_dirty, 0))
			ul2_set_picture(atomic_load(&pic_b), atomic_load(&pic_c),
					atomic_load(&pic_s), atomic_load(&pic_h));
		if (ul2_poll(20) < 0) {
			atomic_store(&g_state, ENG_DISCONNECTED);
			break;
		}
		ul2_get_stats(&s);
		if (s.seconds - last_status >= 0.5) {
			int present = 0, fmt = 0;
			if (ul2_signal(&present, &fmt) == 0) {
				atomic_store(&st_signal, present);
				atomic_store(&st_format, fmt);
			}
			last_status = s.seconds;
		}
		if (s.seconds - last_fps_t >= 1.0) {
			atomic_store(&st_fps, (s.frames - last_frames) / (s.seconds - last_fps_t));
			last_frames = s.frames;
			last_fps_t = s.seconds;
		}
		if (s.seconds - last_level_t >= 0.1) {
			atomic_store(&st_level, peak_acc * 1000 / 32768);
			peak_acc = 0;
			last_level_t = s.seconds;
		}
	}
	eng_record_stop();
	ul2_stop();
	ul2_close();
	return NULL;
}

int eng_start(int input, int pal, eng_video_cb cb, void *ctx)
{
	if (g_thread_live)
		eng_stop();
	g_input_cfg = input;
	g_pal = pal;
	g_cb = cb;
	g_ctx = ctx;
	atomic_store(&g_quit, 0);
	atomic_store(&req_input, -1);
	atomic_store(&st_signal, 0);
	atomic_store(&st_fps, 0);
	atomic_store(&g_state, ENG_STARTING);
	if (pthread_create(&g_thread, NULL, capture_main, NULL) != 0) {
		atomic_store(&g_state, ENG_FAILED);
		return -1;
	}
	g_thread_live = 1;
	return 0;
}

void eng_stop(void)
{
	if (!g_thread_live)
		return;
	atomic_store(&g_quit, 1);
	pthread_join(g_thread, NULL);
	g_thread_live = 0;
	if (atomic_load(&g_state) == ENG_RUNNING || atomic_load(&g_state) == ENG_STARTING)
		atomic_store(&g_state, ENG_STOPPED);
}

void eng_get_status(struct eng_status *st)
{
	memset(st, 0, sizeof *st);
	st->state = atomic_load(&g_state);
	st->signal = atomic_load(&st_signal);
	st->format = atomic_load(&st_format);
	st->input = atomic_load(&st_input);
	st->pal = g_pal;
	st->fps = atomic_load(&st_fps);
	st->audio_level = atomic_load(&st_level) / 1000.0f;
	st->out_width = atomic_load(&st_out_w);
	st->out_height = atomic_load(&st_out_h);
	pthread_mutex_lock(&rec_lock);
	st->recording = rec_active();
	if (st->recording) {
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		st->rec_seconds = (now.tv_sec - rec_t0.tv_sec) + (now.tv_nsec - rec_t0.tv_nsec) / 1e9;
	}
	pthread_mutex_unlock(&rec_lock);
}

void eng_set_input(int input) { atomic_store(&req_input, input ? 1 : 0); }
void eng_set_deinterlace(int mode) { atomic_store(&deint_mode, mode); }
void eng_set_crop(int on) { atomic_store(&crop_on, on ? 1 : 0); }

void eng_set_picture(int brightness, int contrast, int saturation, int hue)
{
	atomic_store(&pic_b, brightness);
	atomic_store(&pic_c, contrast);
	atomic_store(&pic_s, saturation);
	atomic_store(&pic_h, hue);
	atomic_store(&pic_dirty, 1);
}

int eng_ffmpeg_available(void) { return rec_find_ffmpeg() != NULL; }
const char *eng_ffmpeg_path(void) { return rec_find_ffmpeg(); }

int eng_record_start(const char *path)
{
	int mode = atomic_load(&deint_mode), r;

	if (atomic_load(&g_state) != ENG_RUNNING)
		return -1;
	pthread_mutex_lock(&rec_lock);
	rec_w = atomic_load(&st_out_w);
	rec_h = atomic_load(&st_out_h);
	r = rec_start(path, rec_w, rec_h, g_pal,
		      mode == ENG_DEINT_OFF ? 0 : mode == ENG_DEINT_BLEND ? 1 : 2, 1);
	clock_gettime(CLOCK_MONOTONIC, &rec_t0);
	pthread_mutex_unlock(&rec_lock);
	return r;
}

int eng_record_stop(void)
{
	int r;
	/* rec_stop waits for ffmpeg; don't hold rec_lock (the capture thread
	 * takes it per frame), rec_push is already safe against a stop */
	if (!rec_active())
		return 0;
	r = rec_stop();
	return r;
}
