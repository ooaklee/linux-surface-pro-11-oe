#include "g6_pen.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__

#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct g6_uinput {
	int fd;
};

#ifdef __GLIBC__
typedef unsigned long g6_ioctl_request_t;
#else
typedef int g6_ioctl_request_t;
#endif

static int g6_ioctl_bit(int fd, g6_ioctl_request_t request, int bit,
			char *error, size_t error_len)
{
	if (ioctl(fd, request, bit) < 0) {
		snprintf(error, error_len, "uinput capability %d: %s",
			 bit, strerror(errno));
		return -errno;
	}
	return 0;
}

static int g6_abs_setup(int fd, uint16_t code, int32_t minimum,
			int32_t maximum, int32_t resolution,
			char *error, size_t error_len)
{
	struct uinput_abs_setup setup;

	memset(&setup, 0, sizeof(setup));
	setup.code = code;
	setup.absinfo.minimum = minimum;
	setup.absinfo.maximum = maximum;
	setup.absinfo.resolution = resolution;
	if (ioctl(fd, UI_ABS_SETUP, &setup) < 0) {
		snprintf(error, error_len, "uinput axis %u: %s", code,
			 strerror(errno));
		return -errno;
	}
	return 0;
}

struct g6_uinput *g6_uinput_open(const char *path, const struct g6_mapping *mapping,
				char *error, size_t error_len)
{
	struct uinput_setup setup;
	struct g6_uinput *device;
	int fd, result;
	const int keys[] = { BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH,
			     BTN_STYLUS, BTN_STYLUS2 };
	size_t i;

	fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		snprintf(error, error_len, "%s: %s", path, strerror(errno));
		return NULL;
	}
	result = g6_ioctl_bit(fd, UI_SET_EVBIT, EV_KEY, error, error_len);
	if (!result)
		result = g6_ioctl_bit(fd, UI_SET_EVBIT, EV_ABS, error, error_len);
	if (!result)
		result = g6_ioctl_bit(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT,
				      error, error_len);
	for (i = 0; !result && i < sizeof(keys) / sizeof(keys[0]); i++)
		result = g6_ioctl_bit(fd, UI_SET_KEYBIT, keys[i], error, error_len);
	if (result)
		goto fail;

	memset(&setup, 0, sizeof(setup));
	snprintf(setup.name, sizeof(setup.name), "Surface G6 synthesized pen");
	setup.id.bustype = BUS_VIRTUAL;
	setup.id.vendor = 0x045e;
	setup.id.product = 0x0c83;
	setup.id.version = G6_HEAT_ABI_VERSION;
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
		snprintf(error, error_len, "uinput device setup: %s", strerror(errno));
		goto fail;
	}
	if (g6_abs_setup(fd, ABS_X, 0, mapping->x_max, 100,
			 error, error_len) ||
	    g6_abs_setup(fd, ABS_Y, 0, mapping->y_max, 100,
			 error, error_len) ||
	    g6_abs_setup(fd, ABS_PRESSURE, 0, 4096, 0,
			 error, error_len) ||
	    g6_abs_setup(fd, ABS_TILT_X, -9000, 9000, 5730,
			 error, error_len) ||
	    g6_abs_setup(fd, ABS_TILT_Y, -9000, 9000, 5730,
			 error, error_len))
		goto fail;
	if (ioctl(fd, UI_DEV_CREATE) < 0) {
		snprintf(error, error_len, "uinput create: %s", strerror(errno));
		goto fail;
	}
	device = calloc(1, sizeof(*device));
	if (!device) {
		snprintf(error, error_len, "out of memory");
		ioctl(fd, UI_DEV_DESTROY);
		goto fail;
	}
	device->fd = fd;
	return device;

fail:
	close(fd);
	return NULL;
}

static int g6_write_event(int fd, uint16_t type, uint16_t code, int32_t value)
{
	struct input_event event;
	ssize_t written;

	memset(&event, 0, sizeof(event));
	event.type = type;
	event.code = code;
	event.value = value;
	written = write(fd, &event, sizeof(event));
	if (written == (ssize_t)sizeof(event))
		return 0;
	return written < 0 ? -errno : -EIO;
}

int g6_uinput_emit(struct g6_uinput *device, const struct g6_pen_state *state)
{
	int result;
	bool in_range = (state->valid & G6_VALID_PROXIMITY) && state->proximity;
	bool tool_valid = (state->valid & G6_VALID_TOOL) != 0;
	bool pen = in_range && tool_valid && !state->eraser;
	bool rubber = in_range && tool_valid && state->eraser;

#define G6_EVENT(_type, _code, _value) do { \
	result = g6_write_event(device->fd, (_type), (_code), (_value)); \
	if (result) return result; \
} while (0)
	G6_EVENT(EV_KEY, BTN_TOOL_PEN, pen);
	G6_EVENT(EV_KEY, BTN_TOOL_RUBBER, rubber);
	G6_EVENT(EV_KEY, BTN_TOUCH,
		 (state->valid & G6_VALID_PRESSURE) && state->tip);
	G6_EVENT(EV_KEY, BTN_STYLUS,
		 (state->valid & G6_VALID_BUTTONS) && state->barrel);
	G6_EVENT(EV_KEY, BTN_STYLUS2,
		 (state->valid & G6_VALID_BUTTONS) && state->secondary);
	if (state->valid & G6_VALID_POSITION) {
		G6_EVENT(EV_ABS, ABS_X, state->x);
		G6_EVENT(EV_ABS, ABS_Y, state->y);
	}
	G6_EVENT(EV_ABS, ABS_PRESSURE,
		 (state->valid & G6_VALID_PRESSURE) ? state->pressure : 0);
	if (state->valid & G6_VALID_TILT) {
		G6_EVENT(EV_ABS, ABS_TILT_X, state->tilt_x);
		G6_EVENT(EV_ABS, ABS_TILT_Y, state->tilt_y);
	}
	G6_EVENT(EV_SYN, SYN_REPORT, 0);
#undef G6_EVENT
	return 0;
}

void g6_uinput_close(struct g6_uinput *device)
{
	if (!device)
		return;
	ioctl(device->fd, UI_DEV_DESTROY);
	close(device->fd);
	free(device);
}

#else

struct g6_uinput {
	int unused;
};

struct g6_uinput *g6_uinput_open(const char *path, const struct g6_mapping *mapping,
				char *error, size_t error_len)
{
	(void)path;
	(void)mapping;
	snprintf(error, error_len, "uinput is only available on Linux");
	errno = ENOSYS;
	return NULL;
}

int g6_uinput_emit(struct g6_uinput *device, const struct g6_pen_state *state)
{
	(void)device;
	(void)state;
	return -ENOSYS;
}

void g6_uinput_close(struct g6_uinput *device)
{
	(void)device;
}

#endif
