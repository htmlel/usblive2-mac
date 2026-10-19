/* imgutil.h - YUYV helpers shared by the tools.  SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef IMGUTIL_H
#define IMGUTIL_H
#include <stddef.h>
#include <stdint.h>
int save_bmp(const char *path, const uint8_t *yuyv, int w, int h);
int average_luma(const uint8_t *yuyv, size_t size);
#endif
