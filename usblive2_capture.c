/*
 * usblive2_capture.c - command-line capture test for the Hauppauge USB-Live2.
 * Saves a few BMP snapshots and optionally a raw YUYV file.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ul2.h"
#include "imgutil.h"

static volatile sig_atomic_t g_stop;
static struct {
	const char *input;
	int pal, seconds, snapshots, bulk, verbose;
	const char *raw_path, *wav_path;
	int no_audio;
} opt = { "composite", 0, 5, 3, 0, 0, NULL, NULL, 0 };
static int saved;
static FILE *raw, *wav;
static uint32_t wav_bytes;
static int audio_peak;

static void wav_header(FILE *f, uint32_t data_bytes)
{
	uint8_t h[44] = { 'R','I','F','F', 0,0,0,0, 'W','A','V','E', 'f','m','t',' ',
		16,0,0,0, 1,0, 2,0, 0x80,0xbb,0,0, 0x00,0xee,0x02,0, 4,0, 16,0,
		'd','a','t','a', 0,0,0,0 };
	uint32_t riff = data_bytes + 36;
	memcpy(h + 4, &riff, 4);       /* little-endian hosts (Apple Silicon / x86) */
	memcpy(h + 40, &data_bytes, 4);
	fseek(f, 0, SEEK_SET);
	fwrite(h, 1, 44, f);
}

static void on_audio(const int16_t *samples, int frames, void *user)
{
	(void)user;
	for (int i = 0; i < frames * 2; i++) {
		int v = samples[i] < 0 ? -samples[i] : samples[i];
		if (v > audio_peak)
			audio_peak = v;
	}
	if (wav) {
		fwrite(samples, 4, frames, wav);
		wav_bytes += frames * 4;
	}
}

static void on_frame(const uint8_t *yuyv, int w, int h, void *user)
{
	struct ul2_stats s;
	size_t size = (size_t)w * h * 2;

	(void)user;
	if (raw)
		fwrite(yuyv, 1, size, raw);
	ul2_get_stats(&s);
	/* snapshots spread over the run, skipping the first second while the decoder settles */
	if (saved < opt.snapshots && s.seconds > 1.0 &&
	    s.seconds > (double)saved * opt.seconds / opt.snapshots) {
		char name[64];
		snprintf(name, sizeof name, "usblive2_frame_%d.bmp", ++saved);
		save_bmp(name, yuyv, w, h);
		printf("  saved %s (average brightness %d/255)\n", name, average_luma(yuyv, size));
	}
}

static void on_sigint(int s) { (void)s; g_stop = 1; }

static void usage(void)
{
	printf("usage: usblive2_capture [--input composite|svideo] [--pal] [--seconds N]\n"
	       "                        [--snapshots N] [--raw FILE.yuv] [--wav FILE.wav]\n"
	       "                        [--no-audio] [--bulk] [-v|-vv]\n");
}

int main(int argc, char **argv)
{
	struct ul2_config cfg = { 0 };
	struct ul2_stats s;
	double last = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--input") && i + 1 < argc) opt.input = argv[++i];
		else if (!strcmp(argv[i], "--pal")) opt.pal = 1;
		else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) opt.seconds = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--snapshots") && i + 1 < argc) opt.snapshots = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--raw") && i + 1 < argc) opt.raw_path = argv[++i];
		else if (!strcmp(argv[i], "--wav") && i + 1 < argc) opt.wav_path = argv[++i];
		else if (!strcmp(argv[i], "--no-audio")) opt.no_audio = 1;
		else if (!strcmp(argv[i], "--bulk")) opt.bulk = 1;
		else if (!strcmp(argv[i], "-v")) opt.verbose = 1;
		else if (!strcmp(argv[i], "-vv")) opt.verbose = 2;
		else { usage(); return 1; }
	}
	if (strcmp(opt.input, "composite") && strcmp(opt.input, "svideo")) { usage(); return 1; }
	if (opt.seconds < 1) opt.seconds = 1;

	cfg.input = strcmp(opt.input, "svideo") ? UL2_INPUT_COMPOSITE : UL2_INPUT_SVIDEO;
	cfg.pal = opt.pal;
	cfg.bulk = opt.bulk;
	cfg.verbose = opt.verbose;
	cfg.no_audio = opt.no_audio;
	if (ul2_open(&cfg, on_frame, NULL) < 0) {
		fprintf(stderr, "\nInitialization failed - send this whole output.\n");
		return 3;
	}
	if (opt.raw_path && !(raw = fopen(opt.raw_path, "wb")))
		fprintf(stderr, "cannot open %s\n", opt.raw_path);
	if (opt.wav_path) {
		if ((wav = fopen(opt.wav_path, "wb")))
			wav_header(wav, 0);
		else
			fprintf(stderr, "cannot open %s\n", opt.wav_path);
	}
	ul2_set_audio_cb(on_audio, NULL);

	signal(SIGINT, on_sigint);
	printf("\nCapturing %d seconds (Ctrl-C to stop early)...\n", opt.seconds);
	if (ul2_start() < 0) {
		ul2_close();
		return 3;
	}
	while (!g_stop) {
		if (ul2_poll(100) < 0) {
			fprintf(stderr, "device stopped streaming\n");
			break;
		}
		ul2_get_stats(&s);
		if (s.seconds - last >= 1.0) {
			int present = 0, fmt = 0;
			ul2_signal(&present, &fmt);
			printf("  %4.1fs  frames %4llu (%.1f fps)  %.1f MB/s  errors %llu  signal: %s"
			       "  audio %.1f kHz, level %d%%\n",
			       s.seconds, (unsigned long long)s.frames, s.frames / s.seconds,
			       s.bytes / s.seconds / 1e6, (unsigned long long)s.packet_errors,
			       present ? "yes" : "NO", s.audio_frames / s.seconds / 1000.0,
			       audio_peak * 100 / 32768);
			audio_peak = 0;
			last = s.seconds;
			if (s.seconds >= opt.seconds)
				break;
		}
	}
	ul2_get_stats(&s);
	ul2_stop();

	printf("\nDone: %llu frames, %llu transfers, %llu packets (%llu with errors), %.1f MB\n",
	       (unsigned long long)s.frames, (unsigned long long)s.transfers,
	       (unsigned long long)s.packets, (unsigned long long)s.packet_errors, s.bytes / 1e6);
	if (raw) {
		fclose(raw);
		printf("Raw video: %s  (play with: ffplay -f rawvideo -pixel_format yuyv422 "
		       "-video_size %dx%d -framerate %s %s)\n", opt.raw_path, ul2_width(),
		       ul2_height(), opt.pal ? "25" : "30000/1001", opt.raw_path);
	}
	if (wav) {
		wav_header(wav, wav_bytes);
		fclose(wav);
		printf("Audio: %s (%.1f seconds)\n", opt.wav_path, wav_bytes / 192000.0);
	}
	if (s.frames == 0)
		printf("No complete frames - send this whole output (try again with -v).\n");
	ul2_close();
	return s.frames ? 0 : 4;
}
