/*
 * ul2.h - USB-Live2 capture core (driver bring-up + streaming), shared by the
 * command-line tool and the viewer app.
 *
 * Threading: call everything from one thread (the "capture thread"). The
 * frame callback runs on that thread, inside ul2_poll().
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef UL2_H
#define UL2_H
#include <stdint.h>

enum { UL2_INPUT_COMPOSITE = 0, UL2_INPUT_SVIDEO = 1 };

struct ul2_config {
	int input;      /* UL2_INPUT_* */
	int pal;        /* 0 = NTSC, 1 = PAL */
	int bulk;       /* use bulk instead of isochronous transfers */
	int verbose;    /* 0, 1 or 2 */
	int quiet;      /* don't print the bring-up steps */
	int no_audio;   /* don't stream audio */
};

struct ul2_stats {
	uint64_t frames, transfers, packets, packet_errors, bytes;
	uint64_t audio_frames;    /* stereo sample frames received */
	double seconds;           /* since streaming started */
};

/* frame: YUYV 4:2:2, width*2 bytes per line, both fields woven */
typedef void (*ul2_frame_cb)(const uint8_t *yuyv, int width, int height, void *user);

/* audio: interleaved stereo signed 16-bit little-endian at 48000 Hz */
typedef void (*ul2_audio_cb)(const int16_t *samples, int frames, void *user);
#define UL2_AUDIO_RATE 48000

int  ul2_open(const struct ul2_config *cfg, ul2_frame_cb cb, void *user);
void ul2_set_audio_cb(ul2_audio_cb cb, void *user);   /* call before ul2_start */
int  ul2_start(void);
int  ul2_poll(int timeout_ms);          /* <0: device gone / all transfers stopped */
void ul2_stop(void);
void ul2_close(void);

int  ul2_set_input(int input);          /* may be called while streaming */
/* picture controls, Linux ranges: brightness 0..255, contrast 0..127,
 * saturation 0..127, hue -128..127 */
int  ul2_set_picture(int brightness, int contrast, int saturation, int hue);
int  ul2_get_input(void);
int  ul2_signal(int *present, int *format);  /* format: 1 NTSC-M, 4 PAL, ... */
void ul2_get_stats(struct ul2_stats *s);
int  ul2_width(void);
int  ul2_height(void);
int  ul2_is_pal(void);
#endif
