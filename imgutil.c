/* imgutil.c - YUYV helpers shared by the tools.  SPDX-License-Identifier: GPL-2.0-or-later */
#include <stdio.h>
#include <stdlib.h>
#include "imgutil.h"

static inline uint8_t clip(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

/* 24-bit BMP, BT.601 limited-range YUV -> RGB */
int save_bmp(const char *path, const uint8_t *yuyv, int w, int h)
{
	int row = (w * 3 + 3) & ~3, size = 54 + row * h;
	uint8_t hdr[54] = { 'B', 'M' };
	FILE *f = fopen(path, "wb");
	uint8_t *line = calloc(1, row);

	if (!f || !line) {
		free(line);
		if (f)
			fclose(f);
		return -1;
	}
#define PUT32(o, v) do { hdr[o] = (v) & 0xff; hdr[o + 1] = ((v) >> 8) & 0xff; \
	hdr[o + 2] = ((v) >> 16) & 0xff; hdr[o + 3] = ((v) >> 24) & 0xff; } while (0)
	PUT32(2, size); PUT32(10, 54); PUT32(14, 40); PUT32(18, w); PUT32(22, h);
	hdr[26] = 1; hdr[28] = 24; PUT32(34, row * h);
	fwrite(hdr, 1, 54, f);
	for (int y = h - 1; y >= 0; y--) {      /* BMP rows are bottom-up */
		const uint8_t *p = yuyv + (size_t)y * w * 2;
		for (int x = 0; x < w; x += 2, p += 4) {
			int u = p[1] - 128, v = p[3] - 128;
			for (int k = 0; k < 2; k++) {
				int c = 298 * (p[k * 2] - 16);
				uint8_t *o = line + (x + k) * 3;
				o[2] = clip((c + 409 * v + 128) >> 8);
				o[1] = clip((c - 100 * u - 208 * v + 128) >> 8);
				o[0] = clip((c + 516 * u + 128) >> 8);
			}
		}
		fwrite(line, 1, row, f);
	}
	fclose(f);
	free(line);
	return 0;
}

int average_luma(const uint8_t *yuyv, size_t size)
{
	uint64_t sum = 0;
	for (size_t i = 0; i < size; i += 2)
		sum += yuyv[i];
	return (int)(sum / (size / 2));
}
