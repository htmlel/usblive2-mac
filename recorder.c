/*
 * recorder.c - records video (+ audio) to an MP4 file by piping to ffmpeg.
 *
 *   video: raw YUYV frames on ffmpeg's stdin
 *   audio: raw S16LE 48 kHz stereo on ffmpeg's fd 3
 *
 * rec_push()/rec_push_audio() are called from the capture thread and never
 * block: data is copied into rings that two writer threads drain into the
 * pipes, so a slow disk or encoder can never stall USB capture.
 *
 * A/V sync: audio is the master clock (a continuous 48 kHz sample stream).
 * If video falls behind the audio timeline (a frame lost on USB), the last
 * frame is repeated; if it runs ahead, a frame is skipped. This keeps the
 * MP4's constant-frame-rate video locked to the sound for any length.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "recorder.h"

extern char **environ;

/* a ring of fixed-size slots drained into a pipe by its own thread */
struct ring {
	pthread_t thread;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	uint8_t **slot;
	size_t *len;
	int n, head, tail, count, closing;
	size_t slot_size;
	int fd;
	uint64_t written, dropped;
};

static struct {
	struct ring video, audio;
	int running, with_audio;
	double fps;
	uint64_t video_frames;       /* frames handed to the video ring */
	uint64_t audio_frames;       /* sample frames handed to the audio ring */
	uint64_t repeated, skipped;
	uint8_t *last_frame;
	size_t frame_size;
	pid_t pid;
	char path[1024];
} R;

/* serialises start/stop (main thread) against pushes (capture thread) */
static pthread_mutex_t api_lock = PTHREAD_MUTEX_INITIALIZER;

const char *rec_find_ffmpeg(void)
{
	static const char *candidates[] = {
		"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg", NULL
	};
	static char found[1024];
	const char *path = getenv("PATH");

	for (int i = 0; candidates[i]; i++)
		if (access(candidates[i], X_OK) == 0)
			return candidates[i];
	if (path) {
		char *copy = strdup(path), *save = NULL;
		for (char *dir = strtok_r(copy, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
			snprintf(found, sizeof found, "%s/ffmpeg", dir);
			if (access(found, X_OK) == 0) {
				free(copy);
				return found;
			}
		}
		free(copy);
	}
	return NULL;
}

/* ------------------------------------------------------------ rings */
static void *ring_writer(void *arg)
{
	struct ring *q = arg;

	pthread_mutex_lock(&q->lock);
	for (;;) {
		while (q->count == 0 && !q->closing)
			pthread_cond_wait(&q->cond, &q->lock);
		if (q->count == 0 && q->closing)
			break;
		uint8_t *buf = q->slot[q->tail];
		size_t len = q->len[q->tail];
		pthread_mutex_unlock(&q->lock);

		size_t off = 0;
		while (off < len) {
			ssize_t n = write(q->fd, buf + off, len - off);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;            /* ffmpeg exited; keep draining */
			off += (size_t)n;
		}

		pthread_mutex_lock(&q->lock);
		q->tail = (q->tail + 1) % q->n;
		q->count--;
		q->written++;
	}
	pthread_mutex_unlock(&q->lock);
	return NULL;
}

static void ring_init(struct ring *q, int n, size_t slot_size, int fd)
{
	memset(q, 0, sizeof *q);
	pthread_mutex_init(&q->lock, NULL);
	pthread_cond_init(&q->cond, NULL);
	q->n = n;
	q->slot_size = slot_size;
	q->slot = calloc(n, sizeof *q->slot);
	q->len = calloc(n, sizeof *q->len);
	for (int i = 0; i < n; i++)
		q->slot[i] = malloc(slot_size);
	q->fd = fd;
	pthread_create(&q->thread, NULL, ring_writer, q);
}

static int ring_put(struct ring *q, const void *data, size_t len)
{
	int ok = 0;

	if (len > q->slot_size)
		len = q->slot_size;
	pthread_mutex_lock(&q->lock);
	if (!q->closing) {
		if (q->count == q->n) {
			q->dropped++;
		} else {
			memcpy(q->slot[q->head], data, len);
			q->len[q->head] = len;
			q->head = (q->head + 1) % q->n;
			q->count++;
			pthread_cond_signal(&q->cond);
			ok = 1;
		}
	}
	pthread_mutex_unlock(&q->lock);
	return ok;
}

static void ring_close(struct ring *q)
{
	pthread_mutex_lock(&q->lock);
	q->closing = 1;
	pthread_cond_signal(&q->cond);
	pthread_mutex_unlock(&q->lock);
	pthread_join(q->thread, NULL);
	close(q->fd);                 /* EOF on this ffmpeg input */
	for (int i = 0; i < q->n; i++)
		free(q->slot[i]);
	free(q->slot);
	free(q->len);
	pthread_mutex_destroy(&q->lock);
	pthread_cond_destroy(&q->cond);
}

/* ------------------------------------------------------------ public */
int rec_start(const char *path, int w, int h, int pal, int deinterlace, int with_audio)
{
	const char *ffmpeg = rec_find_ffmpeg();
	char size[32], log_path[1100];
	int vpipe[2], apipe[2] = { -1, -1 }, logfd;
	posix_spawn_file_actions_t fa;
	const char *argv[80];
	int a = 0;

	if (R.running)
		return 0;
	if (!ffmpeg) {
		fprintf(stderr, "ffmpeg not found - install it with: brew install ffmpeg\n");
		return -1;
	}
	snprintf(size, sizeof size, "%dx%d", w, h);
	snprintf(R.path, sizeof R.path, "%s", path);
	snprintf(log_path, sizeof log_path, "%s.log", path);

	argv[a++] = ffmpeg;
	argv[a++] = "-hide_banner"; argv[a++] = "-loglevel"; argv[a++] = "warning";
	argv[a++] = "-y";
	argv[a++] = "-thread_queue_size"; argv[a++] = "512";
	argv[a++] = "-f"; argv[a++] = "rawvideo";
	argv[a++] = "-pix_fmt"; argv[a++] = "yuyv422";
	argv[a++] = "-video_size"; argv[a++] = size;
	argv[a++] = "-framerate"; argv[a++] = pal ? "25" : "30000/1001";
	argv[a++] = "-i"; argv[a++] = "pipe:0";
	if (with_audio) {
		argv[a++] = "-thread_queue_size"; argv[a++] = "512";
		argv[a++] = "-f"; argv[a++] = "s16le";
		argv[a++] = "-ar"; argv[a++] = "48000";
		argv[a++] = "-ac"; argv[a++] = "2";
		argv[a++] = "-i"; argv[a++] = "pipe:3";
		argv[a++] = "-map"; argv[a++] = "0:v";
		argv[a++] = "-map"; argv[a++] = "1:a";
		argv[a++] = "-c:a"; argv[a++] = "aac";
		argv[a++] = "-b:a"; argv[a++] = "192k";
	}
	if (deinterlace) {             /* 1: yadif (frame rate), 2: yadif=1 (field rate) */
		argv[a++] = "-vf"; argv[a++] = deinterlace == 2 ? "yadif=1" : "yadif";
	}
#ifdef __APPLE__
	argv[a++] = "-c:v"; argv[a++] = "h264_videotoolbox";   /* Apple hardware encoder */
	argv[a++] = "-b:v"; argv[a++] = "12M";
#else
	argv[a++] = "-c:v"; argv[a++] = "libx264";
	argv[a++] = "-preset"; argv[a++] = "veryfast";
	argv[a++] = "-crf"; argv[a++] = "18";
#endif
	argv[a++] = "-pix_fmt"; argv[a++] = "yuv420p";
	argv[a++] = "-aspect"; argv[a++] = "4:3";
	argv[a++] = "-movflags"; argv[a++] = "+faststart";
	argv[a++] = path;
	argv[a] = NULL;

	if (pipe(vpipe) < 0)
		return -1;
	if (with_audio && pipe(apipe) < 0) {
		close(vpipe[0]); close(vpipe[1]);
		return -1;
	}
	/* keep the child's fd 3 slot clear: move the audio read end above it */
	if (with_audio && apipe[0] <= 3) {
		int moved = fcntl(apipe[0], F_DUPFD, 10);
		close(apipe[0]);
		apipe[0] = moved;
	}
	logfd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, vpipe[0], 0);
	if (with_audio)
		posix_spawn_file_actions_adddup2(&fa, apipe[0], 3);
	if (logfd >= 0) {
		posix_spawn_file_actions_adddup2(&fa, logfd, 1);
		posix_spawn_file_actions_adddup2(&fa, logfd, 2);
	}
	posix_spawn_file_actions_addclose(&fa, vpipe[1]);
	if (with_audio)
		posix_spawn_file_actions_addclose(&fa, apipe[1]);
	if (posix_spawn(&R.pid, ffmpeg, &fa, NULL, (char *const *)argv, environ) != 0) {
		posix_spawn_file_actions_destroy(&fa);
		close(vpipe[0]); close(vpipe[1]);
		if (with_audio) { close(apipe[0]); close(apipe[1]); }
		if (logfd >= 0) close(logfd);
		return -1;
	}
	posix_spawn_file_actions_destroy(&fa);
	close(vpipe[0]);
	if (with_audio)
		close(apipe[0]);
	if (logfd >= 0)
		close(logfd);
	/* the write ends must not leak into later ffmpeg children */
	fcntl(vpipe[1], F_SETFD, FD_CLOEXEC);
	if (with_audio)
		fcntl(apipe[1], F_SETFD, FD_CLOEXEC);
	signal(SIGPIPE, SIG_IGN);      /* a dead ffmpeg must not kill the app */

	R.frame_size = (size_t)w * h * 2;
	R.fps = pal ? 25.0 : 30000.0 / 1001.0;
	R.with_audio = with_audio;
	R.video_frames = R.audio_frames = R.repeated = R.skipped = 0;
	R.last_frame = calloc(1, R.frame_size);
	ring_init(&R.video, 16, R.frame_size, vpipe[1]);
	if (with_audio)
		ring_init(&R.audio, 256, 4096, apipe[1]);   /* ~5 s of audio */
	pthread_mutex_lock(&api_lock);
	R.running = 1;
	pthread_mutex_unlock(&api_lock);
	return 0;
}

static void push_locked(const uint8_t *yuyv)
{
	double target;

	memcpy(R.last_frame, yuyv, R.frame_size);
	if (!R.with_audio || R.audio_frames == 0) {
		R.video_frames += ring_put(&R.video, yuyv, R.frame_size);
		return;
	}
	/* where the video should be, according to the audio clock */
	target = (double)R.audio_frames / 48000.0 * R.fps;
	if ((double)R.video_frames > target + 2.0) {
		R.skipped++;                   /* video ahead: skip this frame */
		return;
	}
	while ((double)R.video_frames + 3.0 < target) {
		if (!ring_put(&R.video, R.last_frame, R.frame_size))
			break;
		R.video_frames++;              /* video behind: repeat a frame */
		R.repeated++;
	}
	R.video_frames += ring_put(&R.video, yuyv, R.frame_size);
}

void rec_push(const uint8_t *yuyv)
{
	pthread_mutex_lock(&api_lock);
	if (R.running)
		push_locked(yuyv);
	pthread_mutex_unlock(&api_lock);
}

void rec_push_audio(const int16_t *samples, int frames)
{
	pthread_mutex_lock(&api_lock);
	/* audio starts with the first video frame, so both begin together */
	if (R.running && R.with_audio && R.video_frames > 0) {
		while (frames > 0) {
			int n = frames > 1024 ? 1024 : frames;
			if (ring_put(&R.audio, samples, (size_t)n * 4))
				R.audio_frames += n;
			samples += n * 2;
			frames -= n;
		}
	}
	pthread_mutex_unlock(&api_lock);
}

int rec_stop(void)
{
	int status = 0;

	pthread_mutex_lock(&api_lock);
	if (!R.running) {
		pthread_mutex_unlock(&api_lock);
		return 0;
	}
	R.running = 0;
	pthread_mutex_unlock(&api_lock);
	ring_close(&R.video);
	if (R.with_audio)
		ring_close(&R.audio);
	waitpid(R.pid, &status, 0);
	free(R.last_frame);
	R.last_frame = NULL;
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

int rec_active(void) { return R.running; }
uint64_t rec_frames(void) { return R.video_frames; }
uint64_t rec_dropped(void) { return R.video.dropped + R.audio.dropped; }
uint64_t rec_repeated(void) { return R.repeated; }
uint64_t rec_skipped(void) { return R.skipped; }
const char *rec_path(void) { return R.path; }
