#define _GNU_SOURCE

#include "g6_pen.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define G6_PACE_INTERVAL_NS UINT64_C(3750000)
#define G6_IDLE_POLL_NS UINT64_C(20000000)

struct g6_sink {
	struct g6_uinput *uinput;
	bool emit_json;
	bool paced;
	struct g6_pacer pacer;
	int error;
};

static volatile sig_atomic_t g6_stop;

static void g6_signal(int signal_number)
{
	(void)signal_number;
	g6_stop = 1;
}

static uint64_t g6_now_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now))
		return 0;
	return (uint64_t)now.tv_sec * UINT64_C(1000000000) +
	       (uint64_t)now.tv_nsec;
}

static void g6_dispatch_state(struct g6_sink *sink,
			      const struct g6_pen_state *state)
{
	if (sink->emit_json) {
		printf("{\"timestamp_ns\":%" PRIu64
		       ",\"generation\":%" PRIu32
		       ",\"valid\":%" PRIu32
		       ",\"proximity\":%s,\"tool\":\"%s\""
		       ",\"tip\":%s,\"barrel\":%s,\"secondary\":%s"
		       ",\"x\":%" PRId32 ",\"y\":%" PRId32
		       ",\"pressure\":%" PRId32
		       ",\"tilt_x\":%" PRId32 ",\"tilt_y\":%" PRId32
		       ",\"quality\":%u}\n",
		       state->timestamp_ns, state->generation, state->valid,
		       state->proximity ? "true" : "false",
		       state->eraser ? "eraser" : "pen",
		       state->tip ? "true" : "false",
		       state->barrel ? "true" : "false",
		       state->secondary ? "true" : "false",
		       state->x, state->y, state->pressure,
		       state->tilt_x, state->tilt_y, state->quality);
		fflush(stdout);
	}
	if (sink->uinput && !sink->error) {
		sink->error = g6_uinput_emit(sink->uinput, state);
		if (sink->error)
			fprintf(stderr, "g6-pen: uinput write failed: %s\n",
				strerror(-sink->error));
	}
}

static void g6_emit_state(void *userdata, const struct g6_pen_state *state)
{
	struct g6_sink *sink = userdata;

	if (state->valid & G6_VALID_TAP) {
		/* Bypass pacing so the following lift's cancel cannot swallow taps. */
		g6_dispatch_state(sink, state);
		return;
	}
	if (!sink->paced) {
		g6_dispatch_state(sink, state);
		return;
	}
	if (!state->proximity) {
		/* Lift/boundary always preempts queued interpolation immediately. */
		g6_pacer_cancel(&sink->pacer);
		g6_dispatch_state(sink, state);
		return;
	}
	g6_pacer_enqueue(&sink->pacer, state, g6_now_ns());
}

static void g6_sink_flush(struct g6_sink *sink, uint64_t now_ns)
{
	struct g6_pen_state state;

	while (g6_pacer_pop_due(&sink->pacer, now_ns, &state)) {
		g6_dispatch_state(sink, &state);
		if (sink->error)
			break;
	}
}

static uint64_t g6_sink_wait_ns(const struct g6_sink *sink, uint64_t now_ns)
{
	return g6_pacer_wait_ns(&sink->pacer, now_ns, G6_IDLE_POLL_NS);
}

static int g6_feed_wire(struct g6_processor *processor,
			const uint8_t *wire, size_t length)
{
	struct g6_record record;
	char error[160];
	int result;

	result = g6_record_decode(wire, length, &record, error, sizeof(error));
	if (result) {
		fprintf(stderr, "g6-pen: rejected record: %s\n", error);
		return result;
	}
	return g6_processor_feed(processor, &record);
}

static ssize_t g6_read_exact(int fd, uint8_t *buffer, size_t length,
			     bool eof_allowed)
{
	size_t offset = 0;

	while (offset < length) {
		ssize_t count = read(fd, buffer + offset, length - offset);

		if (count > 0) {
			offset += (size_t)count;
			continue;
		}
		if (!count && !offset && eof_allowed)
			return 0;
		if (!count)
			return -ENODATA;
		if (errno == EINTR)
			continue;
		return -errno;
	}
	return (ssize_t)offset;
}

static uint16_t g6_le16(const uint8_t *data)
{
	return (uint16_t)((uint16_t)data[0] |
			  (uint16_t)((uint16_t)data[1] << 8));
}

#ifdef __linux__
static uint32_t g6_le32(const uint8_t *data)
{
	return (uint32_t)data[0] | (uint32_t)data[1] << 8 |
	       (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
}

static uint64_t g6_le64(const uint8_t *data)
{
	return (uint64_t)g6_le32(data) | (uint64_t)g6_le32(data + 4) << 32;
}

static int g6_get_info(int fd, struct g6_heat_info_wire *info)
{
	/* glibc and musl expose different signedness for ioctl's request. */
#ifdef __GLIBC__
	return ioctl(fd, (unsigned long)G6_HEAT_IOC_GET_INFO, info);
#else
	return ioctl(fd, (int)(unsigned int)G6_HEAT_IOC_GET_INFO, info);
#endif
}
#endif

static int g6_replay_binary(struct g6_processor *processor, const char *path,
			    uint64_t *last_timestamp)
{
	uint8_t wire[G6_HEAT_MAX_RECORD];
	int fd, result = 0;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "g6-pen: %s: %s\n", path, strerror(errno));
		return -errno;
	}
	for (;;) {
		ssize_t count;
		uint16_t content_len;
		struct g6_record record;
		char error[160];

		count = g6_read_exact(fd, wire, G6_HEAT_HEADER_LEN, true);
		if (!count)
			break;
		if (count < 0) {
			result = (int)count;
			fprintf(stderr, "g6-pen: truncated replay header\n");
			break;
		}
		content_len = g6_le16(wire + 28);
		if (content_len > G6_HEAT_MAX_CONTENT) {
			result = -EMSGSIZE;
			fprintf(stderr, "g6-pen: replay content is too large\n");
			break;
		}
		count = g6_read_exact(fd, wire + G6_HEAT_HEADER_LEN, content_len,
				      false);
		if (count < 0) {
			result = (int)count;
			fprintf(stderr, "g6-pen: truncated replay payload\n");
			break;
		}
		result = g6_record_decode(wire, G6_HEAT_HEADER_LEN + content_len,
					  &record, error, sizeof(error));
		if (result) {
			fprintf(stderr, "g6-pen: rejected replay record: %s\n", error);
			break;
		}
		*last_timestamp = record.timestamp_ns;
		result = g6_processor_feed(processor, &record);
		if (result && result != -ENOMSG)
			break;
	}
	close(fd);
	return result;
}

static int g6_number(const char *text, uint64_t maximum, uint64_t *number)
{
	char *end;
	unsigned long long parsed;

	if (*text == '-')
		return -EINVAL;
	errno = 0;
	parsed = strtoull(text, &end, 0);
	if (errno || !*text || *end || parsed > maximum)
		return -EINVAL;
	*number = parsed;
	return 0;
}

static int g6_decode_hex(const char *text, uint8_t *content, uint16_t *content_len)
{
	size_t length, i;

	if (!strcmp(text, "-")) {
		*content_len = 0;
		return 0;
	}
	length = strlen(text);
	if ((length & 1) || length / 2 > G6_HEAT_MAX_CONTENT)
		return -EMSGSIZE;
	for (i = 0; i < length / 2; i++) {
		char byte[3] = { text[i * 2], text[i * 2 + 1], 0 };
		char *end;
		unsigned long value;

		if (!isxdigit((unsigned char)byte[0]) ||
		    !isxdigit((unsigned char)byte[1]))
			return -EINVAL;
		errno = 0;
		value = strtoul(byte, &end, 16);
		if (errno || *end || value > UINT8_MAX)
			return -EINVAL;
		content[i] = (uint8_t)value;
	}
	*content_len = (uint16_t)(length / 2);
	return 0;
}

static int g6_replay_text(struct g6_processor *processor, const char *path,
			  uint64_t *last_timestamp)
{
	FILE *file;
	char *line = NULL;
	size_t capacity = 0;
	unsigned long line_number = 0;
	bool have_header = false;
	int result = 0;

	file = fopen(path, "r");
	if (!file) {
		fprintf(stderr, "g6-pen: %s: %s\n", path, strerror(errno));
		return -errno;
	}
	while (getline(&line, &capacity, file) >= 0) {
		char *token[6], *save = NULL, *cursor;
		uint8_t content[G6_HEAT_MAX_CONTENT];
		struct g6_record record;
		uint64_t number;
		unsigned int i;

		line_number++;
		cursor = line;
		while (*cursor == ' ' || *cursor == '\t') cursor++;
		if (!*cursor || *cursor == '\n' || *cursor == '#')
			continue;
		cursor[strcspn(cursor, "\r\n")] = '\0';
		if (!have_header) {
			if (strcmp(cursor, "G6T1")) {
				result = -EPROTO;
				break;
			}
			have_header = true;
			continue;
		}
		for (i = 0; i < 6; i++)
			token[i] = strtok_r(i ? NULL : cursor, " \t", &save);
		if (!token[5] || strtok_r(NULL, " \t", &save)) {
			result = -EINVAL;
			break;
		}
		memset(&record, 0, sizeof(record));
		if (g6_number(token[0], UINT32_MAX, &number)) { result = -EINVAL; break; }
		record.generation = (uint32_t)number;
		if (g6_number(token[1], UINT64_MAX, &record.timestamp_ns)) { result = -EINVAL; break; }
		if (g6_number(token[2], UINT32_MAX, &number)) { result = -EINVAL; break; }
		record.sequence = (uint32_t)number;
		if (g6_number(token[3], UINT8_MAX, &number)) { result = -EINVAL; break; }
		record.report_id = (uint8_t)number;
		if (g6_number(token[4], UINT8_MAX, &number)) { result = -EINVAL; break; }
		record.flags = (uint8_t)number;
		result = g6_decode_hex(token[5], content, &record.content_len);
		if (result)
			break;
		record.content = content;
		*last_timestamp = record.timestamp_ns;
		result = g6_processor_feed(processor, &record);
		if (result && result != -ENOMSG)
			break;
		result = 0;
	}
	if (!have_header && !result)
		result = -EPROTO;
	if (result)
		fprintf(stderr, "g6-pen: %s:%lu: invalid G6T1 record\n",
			path, line_number);
	free(line);
	fclose(file);
	return result;
}

static int g6_open_live(const char *device_path)
{
	int fd = open(device_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);

	if (fd < 0) {
		fprintf(stderr, "g6-pen: %s: %s\n", device_path, strerror(errno));
		return -errno;
	}
#ifdef __linux__
	{
		struct g6_heat_info_wire info;
		const uint8_t *bytes = (const uint8_t *)&info;
		uint64_t flags;

		memset(&info, 0, sizeof(info));
		if (g6_get_info(fd, &info) < 0) {
			int result = -errno;
			fprintf(stderr, "g6-pen: GET_INFO %s: %s\n",
				device_path, strerror(errno));
			close(fd);
			return result;
		}
		flags = g6_le64(bytes + 16);
		if (g6_le16(bytes) != G6_HEAT_ABI_VERSION ||
		    g6_le16(bytes + 2) != sizeof(info) ||
		    g6_le16(bytes + 4) != G6_HEAT_HEADER_LEN ||
		    g6_le32(bytes + 8) != G6_HEAT_MAX_CONTENT ||
		    !g6_le32(bytes + 12) ||
		    (flags & G6_HEAT_F_BOUNDARY) != G6_HEAT_F_BOUNDARY) {
			fprintf(stderr, "g6-pen: %s exposes an incompatible G6 HEAT ABI\n",
				device_path);
			close(fd);
			return -EPROTONOSUPPORT;
		}
	}
#endif
	return fd;
}

static int g6_live(struct g6_processor *processor, struct g6_sink *sink,
		   int fd, uint64_t *last_timestamp)
{
	uint8_t wire[G6_HEAT_MAX_RECORD];
	int result = 0;
	while (!g6_stop && !sink->error) {
		struct pollfd pollfd = { .fd = fd, .events = POLLIN | POLLRDNORM };
		uint64_t now = g6_now_ns();
		uint64_t wait_ns;
		int ready;

		g6_processor_tick(processor, now);
		*last_timestamp = now;
		/* Drain due states even while the raw fd remains continuously ready. */
		g6_sink_flush(sink, now);
		if (sink->error)
			break;
		wait_ns = g6_sink_wait_ns(sink, now);
#ifdef __linux__
		{
			struct timespec timeout = {
				.tv_sec = (time_t)(wait_ns / UINT64_C(1000000000)),
				.tv_nsec = (long)(wait_ns % UINT64_C(1000000000)),
			};
			ready = ppoll(&pollfd, 1, &timeout, NULL);
		}
#else
		ready = poll(&pollfd, 1,
			     (int)((wait_ns + UINT64_C(999999)) / UINT64_C(1000000)));
#endif

		if (!ready) {
			now = g6_now_ns();
			g6_sink_flush(sink, now);
			*last_timestamp = now;
			continue;
		}
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			result = -errno;
			break;
		}
		if (pollfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
			result = -ENODEV;
			break;
		}
		if (pollfd.revents & POLLIN) {
			ssize_t count = read(fd, wire, sizeof(wire));

			if (count < 0 && (errno == EAGAIN || errno == EINTR))
				continue;
			if (count <= 0) {
				result = count ? -errno : -ENODEV;
				break;
			}
			result = g6_feed_wire(processor, wire, (size_t)count);
			if (result && result != -ENOMSG)
				break;
			result = 0;
		}
	}
	if (sink->error)
		return sink->error;
	return result;
}

static void g6_usage(FILE *stream, const char *program)
{
	fprintf(stream,
		"Usage: %s [OPTIONS]\n"
		"  --device PATH          live record device (default /dev/g6ts-heat)\n"
		"  --config PATH          validated map config (default /etc/g6-pen.conf)\n"
		"  --uinput-device PATH   uinput node (default /dev/uinput)\n"
		"  --replay PATH          replay concatenated binary G6H1 records\n"
		"  --replay-text PATH     replay deterministic G6T1 text corpus\n"
		"  --no-uinput            decode without creating an input device\n"
		"  --emit-json            print each typed state as one JSON line\n"
		"  --help                 show this help\n",
		program);
}

int main(int argc, char **argv)
{
	const char *device_path = "/dev/g6ts-heat";
	const char *config_path = "/etc/g6-pen.conf";
	const char *uinput_path = "/dev/uinput";
	const char *replay_path = NULL, *text_path = NULL;
	bool no_uinput = false;
	struct g6_mapping mapping;
	struct g6_processor *processor;
	struct g6_sink sink = { 0 };
	char error[256];
	uint64_t last_timestamp = 0;
	int live_fd = -1, option, result;
	static const struct option options[] = {
		{ "device", required_argument, NULL, 'd' },
		{ "config", required_argument, NULL, 'c' },
		{ "uinput-device", required_argument, NULL, 'u' },
		{ "replay", required_argument, NULL, 'r' },
		{ "replay-text", required_argument, NULL, 't' },
		{ "no-uinput", no_argument, NULL, 'n' },
		{ "emit-json", no_argument, NULL, 'j' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};

	while ((option = getopt_long(argc, argv, "d:c:u:r:t:njh", options, NULL)) != -1) {
		switch (option) {
		case 'd': device_path = optarg; break;
		case 'c': config_path = optarg; break;
		case 'u': uinput_path = optarg; break;
		case 'r': replay_path = optarg; break;
		case 't': text_path = optarg; break;
		case 'n': no_uinput = true; break;
		case 'j': sink.emit_json = true; break;
		case 'h': g6_usage(stdout, argv[0]); return 0;
		default: g6_usage(stderr, argv[0]); return 2;
		}
	}
	if (optind != argc || (replay_path && text_path)) {
		g6_usage(stderr, argv[0]);
		return 2;
	}
	if (replay_path || text_path)
		no_uinput = true;
	sink.paced = !replay_path && !text_path;
	g6_pacer_init(&sink.pacer, G6_PACE_INTERVAL_NS);

	g6_mapping_defaults(&mapping);
	result = g6_mapping_load(&mapping, config_path, error, sizeof(error));
	if (result) {
		fprintf(stderr, "g6-pen: %s\n", error);
		return 2;
	}
	if (!replay_path && !text_path) {
		live_fd = g6_open_live(device_path);
		if (live_fd < 0)
			return 1;
	}
	processor = calloc(1, sizeof(*processor));
	if (!processor) {
		fprintf(stderr, "g6-pen: out of memory\n");
		if (live_fd >= 0)
			close(live_fd);
		return 1;
	}
	g6_processor_init(processor, &mapping, g6_emit_state, &sink);
	if (!no_uinput) {
		sink.uinput = g6_uinput_open(uinput_path, &mapping, error, sizeof(error));
		if (!sink.uinput) {
			fprintf(stderr, "g6-pen: %s\n", error);
			if (live_fd >= 0)
				close(live_fd);
			free(processor);
			return 1;
		}
	}

	signal(SIGINT, g6_signal);
	signal(SIGTERM, g6_signal);
	if (replay_path)
		result = g6_replay_binary(processor, replay_path, &last_timestamp);
	else if (text_path)
		result = g6_replay_text(processor, text_path, &last_timestamp);
	else
		result = g6_live(processor, &sink, live_fd, &last_timestamp);
	if (live_fd >= 0)
		close(live_fd);
	if (!last_timestamp && !replay_path && !text_path)
		last_timestamp = g6_now_ns();
	g6_processor_finish(processor, last_timestamp);

	fprintf(stderr,
		"g6-pen: records=%" PRIu64 " cycles=%" PRIu64
		" decoded=%" PRIu64 " emitted=%" PRIu64
		" incomplete=%" PRIu64 " unanchored=%" PRIu64
		" sequence_gaps=%" PRIu64 " boundaries=%" PRIu64
		" pacing_drops=%" PRIu64 "\n",
		processor->stats.records, processor->stats.complete_cycles,
		processor->stats.decoded_cycles, processor->stats.emitted_states,
		processor->stats.incomplete_cycles,
		processor->stats.unanchored_records,
		processor->stats.sequence_gaps,
		processor->stats.generation_boundaries, sink.pacer.drops);
	g6_uinput_close(sink.uinput);
	free(processor);
	return result ? 1 : 0;
}
