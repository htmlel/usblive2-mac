/* engine_test.c - drives engine.c like the Mac app does, against the simulator */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "engine.h"
#include "imgutil.h"

static int calls, last_w, last_h;
static double delays;
static unsigned char snap[720 * 480 * 2];

static void on_video(const uint8_t *yuyv, int w, int h, double delay, void *ctx)
{
	(void)ctx;
	calls++; last_w = w; last_h = h; delays += delay;
	memcpy(snap, yuyv, (size_t)w * h * 2);
}

static void run(const char *name, double secs)
{
	struct eng_status st;
	int16_t buf[480 * 2];
	int audio = 0;
	calls = 0; delays = 0;
	for (int i = 0; i < (int)(secs * 100); i++) {
		usleep(10000);
		audio += eng_audio_read(buf, 480);
	}
	eng_get_status(&st);
	printf("%-22s callbacks %3d  out %dx%d  fps %.1f  signal %d  input %d  audio %d frames  level %.2f  delay-sum %.2f\n",
	       name, calls, last_w, last_h, st.fps, st.signal, st.input, audio, st.audio_level, delays);
}

int main(void)
{
	struct eng_status st;
	eng_start(0, 0, on_video, NULL);
	for (int i = 0; i < 300; i++) {
		eng_get_status(&st);
		if (st.state != ENG_STARTING) break;
		usleep(10000);
	}
	printf("state %d (2 = running)\n", st.state);
	eng_set_deinterlace(ENG_DEINT_OFF);    run("weave", 1.5);
	eng_set_deinterlace(ENG_DEINT_BLEND);  run("blend", 1.5);
	eng_set_deinterlace(ENG_DEINT_SMOOTH); run("smooth (2 per frame)", 1.5);
	save_bmp("engine_smooth.bmp", snap, last_w, last_h);
	eng_set_crop(1);                       run("smooth + crop", 1.0);
	eng_set_input(1);                      run("svideo", 1.0);
	eng_set_picture(160, 64, 64, 0);       run("brightness up", 1.0);
	printf("record start: %d\n", eng_record_start("engine_test.mp4"));
	run("recording", 2.5);
	eng_get_status(&st);
	printf("recording=%d rec_seconds=%.1f\n", st.recording, st.rec_seconds);
	printf("record stop: %d\n", eng_record_stop());
	eng_stop();
	eng_get_status(&st);
	printf("final state %d\n", st.state);
	return 0;
}
