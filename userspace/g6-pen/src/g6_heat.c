#define _POSIX_C_SOURCE 200809L

#include "g6_pen.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t g6_get_le16(const uint8_t *p)
{
	return (uint16_t)((uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8));
}

static uint32_t g6_get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
	       (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t g6_get_le64(const uint8_t *p)
{
	return (uint64_t)g6_get_le32(p) |
	       (uint64_t)g6_get_le32(p + 4) << 32;
}

static void g6_put_le16(uint8_t *p, uint16_t value)
{
	p[0] = (uint8_t)value;
	p[1] = (uint8_t)(value >> 8);
}

static void g6_put_le32(uint8_t *p, uint32_t value)
{
	p[0] = (uint8_t)value;
	p[1] = (uint8_t)(value >> 8);
	p[2] = (uint8_t)(value >> 16);
	p[3] = (uint8_t)(value >> 24);
}

static void g6_put_le64(uint8_t *p, uint64_t value)
{
	g6_put_le32(p, (uint32_t)value);
	g6_put_le32(p + 4, (uint32_t)(value >> 32));
}

static void g6_error(char *error, size_t error_len, const char *message)
{
	if (error && error_len)
		snprintf(error, error_len, "%s", message);
}

int g6_record_decode(const uint8_t *wire, size_t wire_len,
		     struct g6_record *record, char *error, size_t error_len)
{
	uint16_t header_len, content_len, version;
	uint32_t magic, record_len;

	if (!wire || !record || wire_len < G6_HEAT_HEADER_LEN) {
		g6_error(error, error_len, "record is shorter than the v1 header");
		return -EINVAL;
	}

	magic = g6_get_le32(wire);
	version = g6_get_le16(wire + 4);
	header_len = g6_get_le16(wire + 6);
	record_len = g6_get_le32(wire + 8);
	content_len = g6_get_le16(wire + 28);

	if (magic != G6_HEAT_MAGIC) {
		g6_error(error, error_len, "record magic is not G6H1");
		return -EPROTO;
	}
	if (version != G6_HEAT_ABI_VERSION || header_len != G6_HEAT_HEADER_LEN) {
		g6_error(error, error_len, "unsupported g6 heat ABI version/header");
		return -EPROTONOSUPPORT;
	}
	if (content_len > G6_HEAT_MAX_CONTENT ||
	    record_len != (uint32_t)header_len + content_len ||
	    record_len != wire_len) {
		g6_error(error, error_len, "inconsistent record/content length");
		return -EMSGSIZE;
	}

	record->generation = g6_get_le32(wire + 12);
	record->timestamp_ns = g6_get_le64(wire + 16);
	record->sequence = g6_get_le32(wire + 24);
	record->content_len = content_len;
	record->report_id = wire[30];
	record->flags = wire[31];
	record->content = wire + header_len;

	if ((record->flags & G6_HEAT_F_BOUNDARY) &&
	    (record->report_id || record->content_len)) {
		g6_error(error, error_len, "boundary record has report content");
		return -EPROTO;
	}

	return 0;
}

size_t g6_record_encode(uint8_t *wire, size_t wire_len,
			const struct g6_record *record)
{
	size_t total;

	if (!wire || !record || record->content_len > G6_HEAT_MAX_CONTENT)
		return 0;
	total = G6_HEAT_HEADER_LEN + record->content_len;
	if (wire_len < total || (record->content_len && !record->content))
		return 0;

	memset(wire, 0, G6_HEAT_HEADER_LEN);
	g6_put_le32(wire, G6_HEAT_MAGIC);
	g6_put_le16(wire + 4, G6_HEAT_ABI_VERSION);
	g6_put_le16(wire + 6, G6_HEAT_HEADER_LEN);
	g6_put_le32(wire + 8, (uint32_t)total);
	g6_put_le32(wire + 12, record->generation);
	g6_put_le64(wire + 16, record->timestamp_ns);
	g6_put_le32(wire + 24, record->sequence);
	g6_put_le16(wire + 28, record->content_len);
	wire[30] = record->report_id;
	wire[31] = record->flags;
	if (record->content_len)
		memcpy(wire + G6_HEAT_HEADER_LEN, record->content,
		       record->content_len);
	return total;
}

void g6_mapping_defaults(struct g6_mapping *mapping)
{
	memset(mapping, 0, sizeof(*mapping));
	mapping->tap_enabled = true;
	mapping->log_energy = false;
	mapping->report_id = 0x0b;
	mapping->report_instance = 1;
	mapping->decoder = G6_DECODER_RECT_CENTROID;
	mapping->sample_format = G6_SAMPLE_S16_LE;
	mapping->polarity = G6_POLARITY_ABSOLUTE;
	mapping->min_trailer_valid = 0;
	mapping->x_max = 27388;
	mapping->y_max = 18258;
	mapping->acquire_frames = 2;
	mapping->release_frames = 2;
	mapping->stale_ns = UINT64_C(1000000000);
	mapping->tap_min_ms = 60;
	mapping->tap_max_ms = 800;
	mapping->tap_still_delta_permille = 20;
}

static char *g6_trim(char *text)
{
	char *end;

	while (isspace((unsigned char)*text))
		text++;
	end = text + strlen(text);
	while (end > text && isspace((unsigned char)end[-1]))
		*--end = '\0';
	return text;
}

static int g6_parse_bool(const char *text, bool *value)
{
	if (!strcmp(text, "true") || !strcmp(text, "yes") || !strcmp(text, "1"))
		*value = true;
	else if (!strcmp(text, "false") || !strcmp(text, "no") || !strcmp(text, "0"))
		*value = false;
	else
		return -EINVAL;
	return 0;
}

static int g6_parse_u64(const char *text, uint64_t *value)
{
	char *end;
	unsigned long long parsed;

	if (*text == '-')
		return -EINVAL;
	errno = 0;
	parsed = strtoull(text, &end, 0);
	if (errno || !*text || *end)
		return -EINVAL;
	*value = parsed;
	return 0;
}

static int g6_parse_i32(const char *text, int32_t *value)
{
	char *end;
	long parsed;

	errno = 0;
	parsed = strtol(text, &end, 0);
	if (errno || !*text || *end || parsed < INT32_MIN || parsed > INT32_MAX)
		return -EINVAL;
	*value = (int32_t)parsed;
	return 0;
}

static int g6_assign_size(uint64_t number, size_t *value)
{
#if SIZE_MAX < UINT64_MAX
	if (number > SIZE_MAX)
		return -ERANGE;
#endif
	*value = (size_t)number;
	return 0;
}

static int g6_set_mapping_value(struct g6_mapping *m, const char *key,
				const char *value)
{
	uint64_t number;

	if (!strcmp(key, "hover.enabled"))
		return g6_parse_bool(value, &m->hover_enabled);
	if (!strcmp(key, "tap.enabled"))
		return g6_parse_bool(value, &m->tap_enabled);
	if (!strcmp(key, "debug.log_energy"))
		return g6_parse_bool(value, &m->log_energy);
	if (!strcmp(key, "map.decoder")) {
		if (!strcmp(value, "rect-centroid"))
			m->decoder = G6_DECODER_RECT_CENTROID;
		else if (!strcmp(value, "ff00-0c-max-energy"))
			m->decoder = G6_DECODER_FF00_0C_MAX_ENERGY;
		else
			return -EINVAL;
		return 0;
	}
	if (!strcmp(key, "map.sample_format")) {
		if (!strcmp(value, "u8")) m->sample_format = G6_SAMPLE_U8;
		else if (!strcmp(value, "s8")) m->sample_format = G6_SAMPLE_S8;
		else if (!strcmp(value, "u16le")) m->sample_format = G6_SAMPLE_U16_LE;
		else if (!strcmp(value, "s16le")) m->sample_format = G6_SAMPLE_S16_LE;
		else return -EINVAL;
		return 0;
	}
	if (!strcmp(key, "map.polarity")) {
		if (!strcmp(value, "positive")) m->polarity = G6_POLARITY_POSITIVE;
		else if (!strcmp(value, "negative")) m->polarity = G6_POLARITY_NEGATIVE;
		else if (!strcmp(value, "absolute")) m->polarity = G6_POLARITY_ABSOLUTE;
		else return -EINVAL;
		return 0;
	}
	if (!strcmp(key, "map.baseline"))
		return g6_parse_i32(value, &m->baseline);
	if (!strcmp(key, "map.invert_x"))
		return g6_parse_bool(value, &m->invert_x);
	if (!strcmp(key, "map.invert_y"))
		return g6_parse_bool(value, &m->invert_y);
	if (!strcmp(key, "pen.x_max"))
		return g6_parse_i32(value, &m->x_max);
	if (!strcmp(key, "pen.y_max"))
		return g6_parse_i32(value, &m->y_max);
	if (g6_parse_u64(value, &number))
		return -EINVAL;
	if (!strcmp(key, "map.report_id")) {
		if (number > UINT8_MAX)
			return -ERANGE;
		m->report_id = (uint8_t)number;
	} else if (!strcmp(key, "map.report_instance")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->report_instance = (unsigned int)number;
	} else if (!strcmp(key, "map.offset")) {
		return g6_assign_size(number, &m->offset);
	} else if (!strcmp(key, "map.rows")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->rows = (unsigned int)number;
	} else if (!strcmp(key, "map.columns")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->columns = (unsigned int)number;
	} else if (!strcmp(key, "map.row_stride")) {
		return g6_assign_size(number, &m->row_stride);
	} else if (!strcmp(key, "map.sample_stride")) {
		return g6_assign_size(number, &m->sample_stride);
	} else if (!strcmp(key, "map.cell_threshold")) {
		if (number > UINT32_MAX)
			return -ERANGE;
		m->cell_threshold = (uint32_t)number;
	} else if (!strcmp(key, "map.min_peak")) {
		if (number > UINT32_MAX)
			return -ERANGE;
		m->min_peak = (uint32_t)number;
	} else if (!strcmp(key, "map.min_energy")) {
		m->min_energy = number;
	} else if (!strcmp(key, "map.min_active_cells")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->min_active_cells = (unsigned int)number;
	} else if (!strcmp(key, "map.min_trailer_valid")) {
		if (number > 8)
			return -ERANGE;
		m->min_trailer_valid = (unsigned int)number;
	} else if (!strcmp(key, "quality.full_scale")) {
		m->quality_full_scale = number;
	} else if (!strcmp(key, "tracking.acquire_frames")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->acquire_frames = (unsigned int)number;
	} else if (!strcmp(key, "tracking.release_frames")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->release_frames = (unsigned int)number;
	} else if (!strcmp(key, "tracking.stale_ms")) {
		if (number > UINT64_MAX / UINT64_C(1000000))
			return -ERANGE;
		m->stale_ns = number * UINT64_C(1000000);
	} else if (!strcmp(key, "tap.min_ms")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->tap_min_ms = (unsigned int)number;
	} else if (!strcmp(key, "tap.max_ms")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->tap_max_ms = (unsigned int)number;
	} else if (!strcmp(key, "tap.still_delta_permille")) {
		if (number > UINT_MAX)
			return -ERANGE;
		m->tap_still_delta_permille = (unsigned int)number;
	} else {
		return -ENOENT;
	}
	return 0;
}

static bool g6_size_mul(size_t left, size_t right, size_t *result)
{
	if (right && left > SIZE_MAX / right)
		return false;
	*result = left * right;
	return true;
}

static bool g6_size_add(size_t left, size_t right, size_t *result)
{
	if (left > SIZE_MAX - right)
		return false;
	*result = left + right;
	return true;
}

int g6_mapping_validate(const struct g6_mapping *m, char *error, size_t error_len)
{
	size_t sample_size, row_stride, sample_stride, minimum_row;
	size_t row_offset, column_offset, last;

	if (m->x_max <= 0 || m->y_max <= 0 || !m->acquire_frames ||
	    !m->release_frames || !m->stale_ns) {
		g6_error(error, error_len, "invalid pen range/tracking setting");
		return -EINVAL;
	}
	if (!m->hover_enabled)
		return 0;
	if (m->report_id != 0x0b && m->report_id != 0x0c &&
	    m->report_id != 0x0d && m->report_id != 0x1a) {
		g6_error(error, error_len, "map.report_id is not a core HEAT report");
		return -EINVAL;
	}
	if (!m->min_peak || !m->min_energy || !m->min_active_cells) {
		g6_error(error, error_len, "enabled hover map is incomplete");
		return -EINVAL;
	}
	if (m->decoder == G6_DECODER_FF00_0C_MAX_ENERGY) {
		if (m->report_id != 0x0c || m->report_instance) {
			g6_error(error, error_len,
				 "ff00 decoder requires report 0x0c instance 0");
			return -EINVAL;
		}
		if (m->min_active_cells > 2) {
			g6_error(error, error_len,
				 "ff00 decoder has exactly two axis banks");
			return -EINVAL;
		}
		return 0;
	}
	if (!m->rows || !m->columns) {
		g6_error(error, error_len, "rectangular hover map has no dimensions");
		return -EINVAL;
	}
	if ((uint64_t)m->min_active_cells >
	    (uint64_t)m->rows * m->columns) {
		g6_error(error, error_len, "active-cell threshold exceeds map size");
		return -EINVAL;
	}
	if (m->report_id != 0x0b && m->report_instance) {
		g6_error(error, error_len, "only report 0x0b has two cycle instances");
		return -EINVAL;
	}
	if (m->report_instance > 1) {
		g6_error(error, error_len, "map.report_instance must be 0 or 1");
		return -EINVAL;
	}

	sample_size = (m->sample_format == G6_SAMPLE_U8 ||
		       m->sample_format == G6_SAMPLE_S8) ? 1 : 2;
	sample_stride = m->sample_stride ? m->sample_stride : sample_size;
	if (!g6_size_mul(sample_stride, m->columns, &minimum_row)) {
		g6_error(error, error_len, "map row size overflows size_t");
		return -ERANGE;
	}
	row_stride = m->row_stride ? m->row_stride : minimum_row;
	if (sample_stride < sample_size || row_stride < minimum_row) {
		g6_error(error, error_len, "map strides overlap samples/rows");
		return -EINVAL;
	}
	if (!g6_size_mul(m->rows - 1, row_stride, &row_offset) ||
	    !g6_size_mul(m->columns - 1, sample_stride, &column_offset) ||
	    !g6_size_add(m->offset, row_offset, &last) ||
	    !g6_size_add(last, column_offset, &last) ||
	    !g6_size_add(last, sample_size, &last)) {
		g6_error(error, error_len, "map extent arithmetic overflows size_t");
		return -ERANGE;
	}
	if (last > G6_HEAT_MAX_CONTENT) {
		g6_error(error, error_len, "map extends beyond the ABI payload maximum");
		return -EINVAL;
	}
	return 0;
}

int g6_mapping_load(struct g6_mapping *mapping, const char *path,
		    char *error, size_t error_len)
{
	FILE *file;
	char *line = NULL;
	size_t capacity = 0;
	ssize_t length;
	unsigned long line_number = 0;
	bool trailer_limit_error = false;
	int result = 0;

	file = fopen(path, "r");
	if (!file) {
		snprintf(error, error_len, "%s: %s", path, strerror(errno));
		return -errno;
	}
	while ((length = getline(&line, &capacity, file)) >= 0) {
		char *key, *value, *equals, *comment;
		int set_result;

		(void)length;
		line_number++;
		comment = strchr(line, '#');
		if (comment)
			*comment = '\0';
		key = g6_trim(line);
		if (!*key)
			continue;
		equals = strchr(key, '=');
		if (!equals) {
			result = -EINVAL;
			break;
		}
		*equals = '\0';
		value = g6_trim(equals + 1);
		key = g6_trim(key);
		set_result = g6_set_mapping_value(mapping, key, value);
		if (set_result) {
			trailer_limit_error =
				!strcmp(key, "map.min_trailer_valid") &&
				set_result == -ERANGE;
			result = set_result;
			break;
		}
	}
	if (ferror(file) && !result)
		result = -EIO;
	if (result) {
		if (trailer_limit_error)
			snprintf(error, error_len,
				 "%s:%lu: map.min_trailer_valid must be between 0 and 8"
				 " (each bank has 8 vectors)",
				 path, line_number);
		else
			snprintf(error, error_len,
				 "%s:%lu: invalid or unknown setting",
				 path, line_number);
	}
	free(line);
	fclose(file);
	if (result)
		return result;
	return g6_mapping_validate(mapping, error, error_len);
}
