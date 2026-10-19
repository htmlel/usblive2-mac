/*
 * usblive2_viewer.c - live preview + recording for the Hauppauge USB-Live2
 * (an AmaRecTV-style viewer for macOS).
 *
 * Threads:
 *   main    - SDL window, keyboard, drawing
 *   capture - owns the device: ul2_open / ul2_poll / ul2_set_input
 *   writer  - feeds ffmpeg while recording (recorder.c)
 *
 * Keys:  R record   I input (composite / S-Video)   D deinterlace
 *        M mute   F fullscreen   S snapshot   Q / Esc quit
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "ul2.h"
#include "imgutil.h"
#include "recorder.h"

/* ---------------------------------------------------------- shared state */
static struct {
	SDL_mutex *lock;
	uint8_t *frame;              /* latest frame (YUYV), guarded by lock */
	int w, h;
	int new_frame;
	uint64_t frame_seq;
} F;

static SDL_atomic_t want_quit, want_input, cap_state, sig_present, sig_format, cur_input;
static SDL_atomic_t fps_x100;
enum { CAP_STARTING, CAP_RUNNING, CAP_FAILED, CAP_GONE };

static struct ul2_config cfg;
static SDL_AudioDeviceID audio_out;
static SDL_atomic_t muted;
static int deinterlace = 1;      /* main thread only */
static int autotest;             /* scripted run for testing without a person */

/* ---------------------------------------------------------- capture thread */
static void on_frame(const uint8_t *yuyv, int w, int h, void *user)
{
	(void)user;
	SDL_LockMutex(F.lock);
	if (!F.frame || F.w != w || F.h != h) {
		free(F.frame);
		F.frame = malloc((size_t)w * h * 2);
		F.w = w;
		F.h = h;
	}
	memcpy(F.frame, yuyv, (size_t)w * h * 2);
	F.new_frame = 1;
	F.frame_seq++;
	SDL_UnlockMutex(F.lock);
	rec_push(yuyv);
}

/* live monitoring: keep the output queue short (<= ~100 ms) for low latency */
static void on_audio(const int16_t *samples, int frames, void *user)
{
	(void)user;
	rec_push_audio(samples, frames);
	if (audio_out && !SDL_AtomicGet(&muted) &&
	    SDL_GetQueuedAudioSize(audio_out) < UL2_AUDIO_RATE * 4 / 10)
		SDL_QueueAudio(audio_out, samples, (Uint32)frames * 4);
}

static int capture_thread(void *arg)
{
	struct ul2_stats st;
	double last_status = -1, last_fps_t = 0;
	uint64_t last_fps_frames = 0;

	(void)arg;
	if (ul2_open(&cfg, on_frame, NULL) < 0) {
		SDL_AtomicSet(&cap_state, CAP_FAILED);
		return 0;
	}
	ul2_set_audio_cb(on_audio, NULL);
	if (ul2_start() < 0) {
		SDL_AtomicSet(&cap_state, CAP_FAILED);
		return 0;
	}
	SDL_AtomicSet(&cur_input, ul2_get_input());
	SDL_AtomicSet(&cap_state, CAP_RUNNING);

	while (!SDL_AtomicGet(&want_quit)) {
		int in = SDL_AtomicSet(&want_input, -1);
		if (in >= 0) {
			ul2_set_input(in);
			SDL_AtomicSet(&cur_input, ul2_get_input());
		}
		if (ul2_poll(20) < 0) {
			SDL_AtomicSet(&cap_state, CAP_GONE);
			break;
		}
		ul2_get_stats(&st);
		if (st.seconds - last_status >= 0.5) {
			int present = 0, fmt = 0;
			ul2_signal(&present, &fmt);
			SDL_AtomicSet(&sig_present, present);
			SDL_AtomicSet(&sig_format, fmt);
			last_status = st.seconds;
		}
		if (st.seconds - last_fps_t >= 1.0) {
			SDL_AtomicSet(&fps_x100, (int)((st.frames - last_fps_frames) * 100 /
							(st.seconds - last_fps_t)));
			last_fps_frames = st.frames;
			last_fps_t = st.seconds;
		}
	}
	ul2_stop();
	ul2_close();
	return 0;
}

/* ---------------------------------------------------------- helpers */
/* classic linear-blend deinterlace: out[y] = (in[y-1] + 2*in[y] + in[y+1]) / 4 */
static void blend_deinterlace(uint8_t *dst, const uint8_t *src, int w, int h)
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

static void out_dir(char *buf, size_t n, const char *sub)
{
	const char *home = getenv("HOME");
	snprintf(buf, n, "%s/%s", home ? home : ".", sub);
	mkdir(buf, 0755);
	if (access(buf, W_OK) != 0)
		snprintf(buf, n, ".");
}

static void timestamp_name(char *buf, size_t n, const char *dir, const char *ext)
{
	time_t t = time(NULL);
	struct tm tm;
	char ts[64];
	localtime_r(&t, &tm);
	strftime(ts, sizeof ts, "%Y-%m-%d %H.%M.%S", &tm);
	snprintf(buf, n, "%s/USB-Live2 %s.%s", dir, ts, ext);
}

static void toggle_record(int w, int h)
{
	char dir[1024], path[1200];

	if (rec_active()) {
		uint64_t frames = rec_frames(), dropped = rec_dropped();
		uint64_t fixed = rec_repeated() + rec_skipped();
		int ok = rec_stop() == 0;
		printf("Recording stopped: %llu frames%s%s -> %s%s\n", (unsigned long long)frames,
		       dropped ? " (encoder fell behind, some data dropped)" : "",
		       fixed ? " (A/V sync adjusted)" : "", rec_path(),
		       ok ? "" : "  [ffmpeg reported a problem, see the .log file next to it]");
		if (ok) {
			char log[1300];
			snprintf(log, sizeof log, "%s.log", rec_path());
			remove(log);
		}
		return;
	}
	out_dir(dir, sizeof dir, "Movies");
	timestamp_name(path, sizeof path, dir, "mp4");
	if (rec_start(path, w, h, ul2_is_pal(), deinterlace, !cfg.no_audio) == 0)
		printf("Recording to %s\n", path);
	else
		printf("Could not start recording (is ffmpeg installed? brew install ffmpeg)\n");
}

static void snapshot(const uint8_t *yuyv, int w, int h)
{
	char dir[1024], path[1200];
	out_dir(dir, sizeof dir, "Pictures");
	timestamp_name(path, sizeof path, dir, "bmp");
	if (save_bmp(path, yuyv, w, h) == 0)
		printf("Snapshot saved: %s\n", path);
}

static const char *format_name(int f)
{
	static const char *names[16] = { "-", "NTSC", "NTSC-J", "NTSC-4.43", "PAL", "PAL-M",
		"PAL-N", "PAL-Nc", "PAL-60", "?", "?", "?", "SECAM", "?", "?", "?" };
	return names[f & 15];
}

static void update_title(SDL_Window *win)
{
	char t[256];
	int state = SDL_AtomicGet(&cap_state);
	int fps = SDL_AtomicGet(&fps_x100);

	if (state == CAP_STARTING)
		snprintf(t, sizeof t, "USB-Live2 - starting...");
	else if (state == CAP_FAILED)
		snprintf(t, sizeof t, "USB-Live2 - could not start the device (see Terminal)");
	else if (state == CAP_GONE)
		snprintf(t, sizeof t, "USB-Live2 - device disconnected");
	else {
		char rec[64] = "";
		if (rec_active()) {
			unsigned s = (unsigned)(rec_frames() / (ul2_is_pal() ? 25.0 : 29.97));
			snprintf(rec, sizeof rec, "  |  REC %02u:%02u:%02u", s / 3600, s / 60 % 60, s % 60);
		}
		snprintf(t, sizeof t, "USB-Live2  |  %s  |  %s  |  %d.%02d fps%s%s%s",
			 SDL_AtomicGet(&cur_input) ? "S-Video" : "Composite",
			 SDL_AtomicGet(&sig_present) ? format_name(SDL_AtomicGet(&sig_format)) : "NO SIGNAL",
			 fps / 100, fps % 100, deinterlace ? "  |  deinterlace" : "",
			 cfg.no_audio ? "  |  no audio" : SDL_AtomicGet(&muted) ? "  |  muted" : "", rec);
	}
	SDL_SetWindowTitle(win, t);
}

/* scripted run used for automated testing (UL2_AUTOTEST=1) */
static void autotest_step(double t, int *done_flags, SDL_Renderer *ren, int w, int h)
{
	if (t > 1.0 && !(*done_flags & 1)) { *done_flags |= 1; toggle_record(w, h); }
	if (t > 2.0 && !(*done_flags & 2)) { *done_flags |= 2; SDL_AtomicSet(&want_input, 1); }
	if (t > 3.0 && !(*done_flags & 4)) { *done_flags |= 4; SDL_AtomicSet(&want_input, 0); }
	if (t > 4.0 && !(*done_flags & 8)) {
		int ww, wh;
		*done_flags |= 8;
		SDL_GetRendererOutputSize(ren, &ww, &wh);
		SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, ww, wh, 32, SDL_PIXELFORMAT_ARGB8888);
		SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_ARGB8888, s->pixels, s->pitch);
		SDL_SaveBMP(s, "viewer_window.bmp");
		SDL_FreeSurface(s);
		printf("autotest: window saved to viewer_window.bmp\n");
		toggle_record(w, h);
	}
	if (t > 4.5)
		SDL_AtomicSet(&want_quit, 1);
}

int main(int argc, char **argv)
{
	SDL_Window *win;
	SDL_Renderer *ren;
	SDL_Texture *tex = NULL;
	SDL_Thread *cap;
	uint8_t *work = NULL;
	int tex_w = 0, tex_h = 0, fullscreen = 0, test_flags = 0;
	Uint64 t0, last_title = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--input") && i + 1 < argc)
			cfg.input = !strcmp(argv[++i], "svideo") ? UL2_INPUT_SVIDEO : UL2_INPUT_COMPOSITE;
		else if (!strcmp(argv[i], "--pal")) cfg.pal = 1;
		else if (!strcmp(argv[i], "--bulk")) cfg.bulk = 1;
		else if (!strcmp(argv[i], "--no-deinterlace")) deinterlace = 0;
		else if (!strcmp(argv[i], "--no-audio")) cfg.no_audio = 1;
		else if (!strcmp(argv[i], "--mute")) SDL_AtomicSet(&muted, 1);
		else if (!strcmp(argv[i], "-v")) cfg.verbose = 1;
		else {
			printf("usage: usblive2_viewer [--input composite|svideo] [--pal] [--bulk]\n"
			       "                       [--no-deinterlace] [--no-audio] [--mute] [-v]\n");
			return 1;
		}
	}
	autotest = getenv("UL2_AUTOTEST") != NULL;
	cfg.quiet = 1;

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	if (!cfg.no_audio && SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) {
		SDL_AudioSpec want = { 0 }, have;
		want.freq = UL2_AUDIO_RATE;
		want.format = AUDIO_S16LSB;
		want.channels = 2;
		want.samples = 512;
		audio_out = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
		if (audio_out)
			SDL_PauseAudioDevice(audio_out, 0);
		else
			fprintf(stderr, "no audio output: %s\n", SDL_GetError());
	}
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
	win = SDL_CreateWindow("USB-Live2", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
			       960, 720, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
	ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
	if (!ren)
		ren = SDL_CreateRenderer(win, -1, 0);
	if (!win || !ren) {
		fprintf(stderr, "could not create window: %s\n", SDL_GetError());
		return 1;
	}

	printf("USB-Live2 viewer\n"
	       "  R record   I composite/S-Video   D deinterlace   M mute\n"
	       "  F fullscreen   S snapshot   Q quit\n"
	       "Recordings go to ~/Movies, snapshots to ~/Pictures.\n");
	if (!rec_find_ffmpeg())
		printf("Note: ffmpeg not found, recording disabled (brew install ffmpeg).\n");

	F.lock = SDL_CreateMutex();
	SDL_AtomicSet(&want_input, -1);
	SDL_AtomicSet(&cap_state, CAP_STARTING);
	cap = SDL_CreateThread(capture_thread, "capture", NULL);
	t0 = SDL_GetTicks64();

	while (!SDL_AtomicGet(&want_quit)) {
		SDL_Event e;
		int w = F.w ? F.w : 720, h = F.h ? F.h : 480;

		while (SDL_PollEvent(&e)) {
			if (e.type == SDL_QUIT)
				SDL_AtomicSet(&want_quit, 1);
			else if (e.type == SDL_KEYDOWN && !e.key.repeat) {
				switch (e.key.keysym.sym) {
				case SDLK_q:
					SDL_AtomicSet(&want_quit, 1);
					break;
				case SDLK_ESCAPE:
					if (fullscreen) {
						fullscreen = 0;
						SDL_SetWindowFullscreen(win, 0);
					} else {
						SDL_AtomicSet(&want_quit, 1);
					}
					break;
				case SDLK_r:
					if (SDL_AtomicGet(&cap_state) == CAP_RUNNING)
						toggle_record(w, h);
					break;
				case SDLK_i:
					SDL_AtomicSet(&want_input, !SDL_AtomicGet(&cur_input));
					break;
				case SDLK_m:
					SDL_AtomicSet(&muted, !SDL_AtomicGet(&muted));
					if (SDL_AtomicGet(&muted) && audio_out)
						SDL_ClearQueuedAudio(audio_out);
					break;
				case SDLK_d:
					deinterlace = !deinterlace;
					if (rec_active())
						printf("(deinterlace change applies to the next recording)\n");
					break;
				case SDLK_f:
					fullscreen = !fullscreen;
					SDL_SetWindowFullscreen(win, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
					break;
				case SDLK_s:
					SDL_LockMutex(F.lock);
					if (F.frame)
						snapshot(F.frame, F.w, F.h);
					SDL_UnlockMutex(F.lock);
					break;
				}
			} else if (e.type == SDL_MOUSEBUTTONDOWN && e.button.clicks == 2) {
				fullscreen = !fullscreen;
				SDL_SetWindowFullscreen(win, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
			}
		}

		/* upload the newest frame */
		SDL_LockMutex(F.lock);
		if (F.new_frame) {
			if (!tex || tex_w != F.w || tex_h != F.h) {
				if (tex)
					SDL_DestroyTexture(tex);
				tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_YUY2,
							SDL_TEXTUREACCESS_STREAMING, F.w, F.h);
				tex_w = F.w;
				tex_h = F.h;
				free(work);
				work = malloc((size_t)F.w * F.h * 2);
			}
			if (deinterlace) {
				blend_deinterlace(work, F.frame, F.w, F.h);
				SDL_UpdateTexture(tex, NULL, work, F.w * 2);
			} else {
				SDL_UpdateTexture(tex, NULL, F.frame, F.w * 2);
			}
			F.new_frame = 0;
		}
		SDL_UnlockMutex(F.lock);

		/* draw: picture at 4:3, letterboxed */
		{
			int ow, oh;
			SDL_Rect dst;
			SDL_GetRendererOutputSize(ren, &ow, &oh);
			if (ow * 3 > oh * 4) {
				dst.h = oh; dst.w = oh * 4 / 3;
			} else {
				dst.w = ow; dst.h = ow * 3 / 4;
			}
			dst.x = (ow - dst.w) / 2;
			dst.y = (oh - dst.h) / 2;
			SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
			SDL_RenderClear(ren);
			if (tex)
				SDL_RenderCopy(ren, tex, NULL, &dst);
			if (rec_active() && (SDL_GetTicks64() / 500) % 2 == 0) {
				int r = oh / 40 + 4;
				SDL_Rect dot = { dst.x + dst.w - 3 * r, dst.y + r, 2 * r, 2 * r };
				SDL_SetRenderDrawColor(ren, 230, 30, 30, 255);
				SDL_RenderFillRect(ren, &dot);
			}
			SDL_RenderPresent(ren);
		}

		if (SDL_GetTicks64() - last_title > 500) {
			update_title(win);
			last_title = SDL_GetTicks64();
		}
		if (autotest)
			autotest_step((SDL_GetTicks64() - t0) / 1000.0, &test_flags, ren, w, h);
		if (SDL_AtomicGet(&cap_state) == CAP_FAILED && autotest)
			SDL_AtomicSet(&want_quit, 1);
		SDL_Delay(2);
	}

	if (rec_active())
		toggle_record(F.w, F.h);
	SDL_WaitThread(cap, NULL);
	if (audio_out)
		SDL_CloseAudioDevice(audio_out);
	if (tex)
		SDL_DestroyTexture(tex);
	SDL_DestroyRenderer(ren);
	SDL_DestroyWindow(win);
	SDL_Quit();
	free(work);
	free(F.frame);
	return SDL_AtomicGet(&cap_state) == CAP_FAILED ? 3 : 0;
}
