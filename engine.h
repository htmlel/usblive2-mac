/*
 * engine.h - the USB-Live2 engine used by the Mac app.
 *
 * Owns a capture thread that runs the ported driver (ul2.c), post-processes
 * frames (crop, deinterlace), buffers audio for live playback and feeds the
 * recorder. All functions are safe to call from the app's main thread.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef ENGINE_H
#define ENGINE_H
#include <stdint.h>

enum eng_state {
	ENG_STOPPED = 0,
	ENG_STARTING,
	ENG_RUNNING,
	ENG_NOT_FOUND,      /* device not connected / could not be opened */
	ENG_FAILED,         /* opened but initialisation failed */
	ENG_DISCONNECTED,   /* was running, device went away */
};

enum eng_deinterlace {
	ENG_DEINT_OFF = 0,  /* show both fields woven (raw) */
	ENG_DEINT_BLEND,    /* 29.97 fps, fields blended */
	ENG_DEINT_SMOOTH,   /* 59.94 fps, each field line-doubled ("bob") */
};

/* Called on the capture thread for every picture to show.
 * yuyv: packed YUYV 4:2:2 (Y0 U Y1 V), width*2 bytes per row.
 * delay: seconds after "now" when this picture should be shown
 *        (0, or half a frame for the second field in SMOOTH mode). */
typedef void (*eng_video_cb)(const uint8_t *yuyv, int width, int height,
			     double delay, void *ctx);

struct eng_status {
	int state;              /* enum eng_state */
	int signal;             /* 1 = decoder sees a video signal */
	int format;             /* detected: 1 NTSC-M, 4 PAL, 0 none ... */
	int input;              /* 0 composite, 1 S-Video */
	int pal;
	double fps;             /* frames per second arriving from the device */
	float audio_level;      /* 0..1 peak, recent */
	int recording;
	double rec_seconds;
	int out_width, out_height;
};

int  eng_start(int input, int pal, eng_video_cb cb, void *ctx);   /* returns at once */
void eng_stop(void);                                             /* blocks until stopped */
void eng_get_status(struct eng_status *st);

void eng_set_input(int input);
void eng_set_deinterlace(int mode);
void eng_set_crop(int on);
/* ranges as in the Linux driver: brightness 0..255 (128), contrast 0..127
 * (64), saturation 0..127 (64), hue -128..127 (0) */
void eng_set_picture(int brightness, int contrast, int saturation, int hue);

/* live audio: interleaved stereo S16 at 48 kHz. Fills the rest with silence;
 * safe to call from a real-time audio thread. Returns frames of real audio. */
int  eng_audio_read(int16_t *dst, int frames);

int  eng_record_start(const char *path);   /* MP4, needs ffmpeg; 0 = ok */
int  eng_record_stop(void);                /* 0 = file written ok */
int  eng_ffmpeg_available(void);
const char *eng_ffmpeg_path(void);        /* NULL if ffmpeg isn't installed */
#endif
