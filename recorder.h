/* recorder.h - MP4 recording through ffmpeg.  SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RECORDER_H
#define RECORDER_H
#include <stdint.h>
const char *rec_find_ffmpeg(void);
/* deinterlace: 0 none, 1 yadif at frame rate, 2 yadif at field rate (59.94/50 fps) */
int  rec_start(const char *path, int width, int height, int pal, int deinterlace, int with_audio);
void rec_push(const uint8_t *yuyv);                    /* never blocks */
void rec_push_audio(const int16_t *samples, int frames); /* S16LE stereo 48 kHz, never blocks */
int  rec_stop(void);                                   /* 0 = file finalized OK */
int  rec_active(void);
uint64_t rec_frames(void);
uint64_t rec_dropped(void);
uint64_t rec_repeated(void);
uint64_t rec_skipped(void);
const char *rec_path(void);
#endif
