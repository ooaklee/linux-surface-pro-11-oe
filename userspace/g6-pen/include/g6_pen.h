#ifndef G6_PEN_H
#define G6_PEN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "g6_heat_abi.h"

#define G6_CYCLE_PARTS 5
#define G6_PACER_MAX_STATES 32

enum g6_sample_format {
	G6_SAMPLE_U8,
	G6_SAMPLE_S8,
	G6_SAMPLE_U16_LE,
	G6_SAMPLE_S16_LE,
};

enum g6_polarity {
	G6_POLARITY_POSITIVE,
	G6_POLARITY_NEGATIVE,
	G6_POLARITY_ABSOLUTE,
};

enum g6_decoder {
	G6_DECODER_RECT_CENTROID,
	G6_DECODER_FF00_0C_MAX_ENERGY,
};

enum g6_valid_field {
	G6_VALID_PROXIMITY = 1U << 0,
	G6_VALID_POSITION = 1U << 1,
	G6_VALID_PRESSURE = 1U << 2,
	G6_VALID_TILT = 1U << 3,
	G6_VALID_BUTTONS = 1U << 4,
	G6_VALID_TOOL = 1U << 5,
	G6_VALID_QUALITY = 1U << 6,
};

enum g6_tracking_state {
	G6_TRACK_CLOSED,
	G6_TRACK_WAIT_CLEAR,
	G6_TRACK_ACQUIRING,
	G6_TRACK_HOVER,
};

struct g6_record {
	uint32_t generation;
	uint64_t timestamp_ns;
	uint32_t sequence;
	uint16_t content_len;
	uint8_t report_id;
	uint8_t flags;
	const uint8_t *content;
};

struct g6_mapping {
	bool hover_enabled;
	enum g6_decoder decoder;
	uint8_t report_id;
	unsigned int report_instance;
	size_t offset;
	unsigned int rows;
	unsigned int columns;
	size_t row_stride;
	size_t sample_stride;
	enum g6_sample_format sample_format;
	int32_t baseline;
	enum g6_polarity polarity;
	uint32_t cell_threshold;
	uint32_t min_peak;
	uint64_t min_energy;
	unsigned int min_active_cells;
	bool invert_x;
	bool invert_y;
	int32_t x_max;
	int32_t y_max;
	uint64_t quality_full_scale;
	unsigned int acquire_frames;
	unsigned int release_frames;
	uint64_t stale_ns;
};

struct g6_pen_state {
	uint64_t timestamp_ns;
	uint32_t generation;
	uint32_t valid;
	bool proximity;
	bool eraser;
	bool tip;
	bool barrel;
	bool secondary;
	int32_t x;
	int32_t y;
	int32_t pressure;
	int32_t tilt_x;
	int32_t tilt_y;
	uint16_t quality;
};

struct g6_part {
	bool present;
	uint8_t report_id;
	uint16_t content_len;
	uint64_t timestamp_ns;
	uint8_t content[G6_HEAT_MAX_CONTENT];
};

struct g6_cycle {
	uint32_t generation;
	uint64_t first_timestamp_ns;
	uint64_t last_timestamp_ns;
	struct g6_part part[G6_CYCLE_PARTS];
};

struct g6_stats {
	uint64_t records;
	uint64_t sideband_records;
	uint64_t invalid_records;
	uint64_t unanchored_records;
	uint64_t sequence_gaps;
	uint64_t incomplete_cycles;
	uint64_t complete_cycles;
	uint64_t decoded_cycles;
	uint64_t emitted_states;
	uint64_t generation_boundaries;
	uint64_t stale_lifts;
};

struct g6_paced_state {
	struct g6_pen_state state;
	uint64_t due_ns;
};

struct g6_pacer {
	struct g6_paced_state pending[G6_PACER_MAX_STATES];
	unsigned int head;
	unsigned int count;
	uint64_t interval_ns;
	uint64_t last_due_ns;
	uint64_t drops;
};

typedef void (*g6_emit_fn)(void *userdata, const struct g6_pen_state *state);

struct g6_processor {
	struct g6_mapping mapping;
	struct g6_cycle cycle;
	struct g6_stats stats;
	enum g6_tracking_state tracking;
	uint32_t generation;
	bool generation_valid;
	bool sequence_valid;
	uint32_t last_sequence;
	bool await_clear;
	unsigned int positive_frames;
	unsigned int negative_frames;
	bool have_last_point;
	int32_t last_x;
	int32_t last_y;
	uint16_t last_quality;
	uint64_t last_point_ns;
	uint64_t last_complete_ns;
	g6_emit_fn emit;
	void *emit_userdata;
};

void g6_mapping_defaults(struct g6_mapping *mapping);
int g6_mapping_load(struct g6_mapping *mapping, const char *path,
		    char *error, size_t error_len);
int g6_mapping_validate(const struct g6_mapping *mapping,
			char *error, size_t error_len);

int g6_record_decode(const uint8_t *wire, size_t wire_len,
		     struct g6_record *record, char *error, size_t error_len);
size_t g6_record_encode(uint8_t *wire, size_t wire_len,
			const struct g6_record *record);

void g6_processor_init(struct g6_processor *processor,
		       const struct g6_mapping *mapping,
		       g6_emit_fn emit, void *emit_userdata);
int g6_processor_feed(struct g6_processor *processor,
		      const struct g6_record *record);
void g6_processor_tick(struct g6_processor *processor, uint64_t now_ns);
void g6_processor_finish(struct g6_processor *processor, uint64_t timestamp_ns);

void g6_pacer_init(struct g6_pacer *pacer, uint64_t interval_ns);
void g6_pacer_enqueue(struct g6_pacer *pacer,
		      const struct g6_pen_state *state, uint64_t now_ns);
bool g6_pacer_pop_due(struct g6_pacer *pacer, uint64_t now_ns,
		      struct g6_pen_state *state);
uint64_t g6_pacer_wait_ns(const struct g6_pacer *pacer, uint64_t now_ns,
			  uint64_t maximum_ns);
void g6_pacer_cancel(struct g6_pacer *pacer);

struct g6_uinput;
struct g6_uinput *g6_uinput_open(const char *path, const struct g6_mapping *mapping,
				char *error, size_t error_len);
int g6_uinput_emit(struct g6_uinput *device, const struct g6_pen_state *state);
void g6_uinput_close(struct g6_uinput *device);

#endif
