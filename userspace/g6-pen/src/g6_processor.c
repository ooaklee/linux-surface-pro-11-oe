#include "g6_pen.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define G6_CYCLE_WINDOW_NS UINT64_C(30000000)
#define G6_INDEX_MARGIN_PERMILLE 1250
#define G6_INDEX_FRAMES 2

enum g6_part_index {
	G6_PART_0C,
	G6_PART_0B_FIRST,
	G6_PART_0B_SECOND,
	G6_PART_1A,
	G6_PART_0D,
};

struct g6_candidate {
	bool present;
	int32_t x;
	int32_t y;
	uint16_t quality;
};

static unsigned int g6_cycle_count(const struct g6_cycle *cycle)
{
	unsigned int i, count = 0;

	for (i = 0; i < G6_CYCLE_PARTS; i++)
		count += cycle->part[i].present;
	return count;
}

static void g6_cycle_clear(struct g6_processor *processor, bool incomplete)
{
	if (incomplete && g6_cycle_count(&processor->cycle))
		processor->stats.incomplete_cycles++;
	memset(&processor->cycle, 0, sizeof(processor->cycle));
}

static bool g6_cycle_complete(const struct g6_cycle *cycle)
{
	unsigned int i;

	for (i = 0; i < G6_CYCLE_PARTS; i++)
		if (!cycle->part[i].present)
			return false;
	return true;
}

static int g6_part_index(struct g6_cycle *cycle, uint8_t report_id)
{
	switch (report_id) {
	case 0x0c:
		return G6_PART_0C;
	case 0x1a:
		return G6_PART_1A;
	case 0x0d:
		return G6_PART_0D;
	case 0x0b:
		if (!cycle->part[G6_PART_0B_FIRST].present)
			return G6_PART_0B_FIRST;
		return G6_PART_0B_SECOND;
	default:
		return -1;
	}
}

static int32_t g6_read_sample(const uint8_t *data, enum g6_sample_format format)
{
	switch (format) {
	case G6_SAMPLE_U8:
		return data[0];
	case G6_SAMPLE_S8:
		return (int8_t)data[0];
	case G6_SAMPLE_U16_LE:
		return (uint16_t)data[0] | (uint16_t)data[1] << 8;
	case G6_SAMPLE_S16_LE:
		return (int16_t)((uint16_t)data[0] | (uint16_t)data[1] << 8);
	}
	return 0;
}

static uint16_t g6_read_le16(const uint8_t *data)
{
	return (uint16_t)((uint16_t)data[0] |
			  (uint16_t)((uint16_t)data[1] << 8));
}

static uint32_t g6_read_le32(const uint8_t *data)
{
	return (uint32_t)data[0] | (uint32_t)data[1] << 8 |
	       (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
}

static uint64_t g6_mul_div_u64(uint64_t left, uint64_t right,
			       uint64_t divisor)
{
	__uint128_t product = (__uint128_t)left * right;

	return (uint64_t)(product / divisor);
}

static const struct g6_part *g6_mapping_part(const struct g6_processor *processor)
{
	const struct g6_mapping *m = &processor->mapping;

	switch (m->report_id) {
	case 0x0c:
		return &processor->cycle.part[G6_PART_0C];
	case 0x1a:
		return &processor->cycle.part[G6_PART_1A];
	case 0x0d:
		return &processor->cycle.part[G6_PART_0D];
	case 0x0b:
		return &processor->cycle.part[m->report_instance ?
			G6_PART_0B_SECOND : G6_PART_0B_FIRST];
	default:
		return NULL;
	}
}

static int g6_decode_rect_cycle(const struct g6_processor *processor,
				struct g6_candidate *candidate)
{
	const struct g6_mapping *m = &processor->mapping;
	const struct g6_part *part;
	size_t sample_size, sample_stride, row_stride, end;
	uint64_t energy = 0, weighted_x = 0, weighted_y = 0;
	uint32_t peak = 0;
	unsigned int active = 0, row, column;

	memset(candidate, 0, sizeof(*candidate));
	if (!m->hover_enabled)
		return -ENODATA;
	part = g6_mapping_part(processor);
	if (!part || !part->present)
		return -ENODATA;

	sample_size = (m->sample_format == G6_SAMPLE_U8 ||
		       m->sample_format == G6_SAMPLE_S8) ? 1 : 2;
	sample_stride = m->sample_stride ? m->sample_stride : sample_size;
	row_stride = m->row_stride ? m->row_stride : sample_stride * m->columns;
	end = m->offset + (m->rows - 1) * row_stride +
	      (m->columns - 1) * sample_stride + sample_size;
	if (end > part->content_len)
		return -EMSGSIZE;

	for (row = 0; row < m->rows; row++) {
		for (column = 0; column < m->columns; column++) {
			const uint8_t *address = part->content + m->offset +
				row * row_stride + column * sample_stride;
			int64_t delta = (int64_t)g6_read_sample(address,
							      m->sample_format) - m->baseline;
			uint32_t weight;

			switch (m->polarity) {
			case G6_POLARITY_POSITIVE:
				weight = delta > 0 ? (uint32_t)delta : 0;
				break;
			case G6_POLARITY_NEGATIVE:
				weight = delta < 0 ? (uint32_t)-delta : 0;
				break;
			case G6_POLARITY_ABSOLUTE:
				weight = (uint32_t)(delta < 0 ? -delta : delta);
				break;
			default:
				weight = 0;
			}
			if (weight < m->cell_threshold)
				continue;
			active++;
			if (weight > peak)
				peak = weight;
			energy += weight;
			weighted_x += (uint64_t)weight * column;
			weighted_y += (uint64_t)weight * row;
		}
	}

	candidate->present = peak >= m->min_peak && energy >= m->min_energy &&
			     active >= m->min_active_cells;
	if (!candidate->present)
		return 0;
	if (m->columns > 1)
		candidate->x = (int32_t)(g6_mul_div_u64(weighted_x,
							   (uint64_t)m->x_max,
							   energy) /
					 (m->columns - 1));
	if (m->rows > 1)
		candidate->y = (int32_t)(g6_mul_div_u64(weighted_y,
							   (uint64_t)m->y_max,
							   energy) /
					 (m->rows - 1));
	if (m->invert_x)
		candidate->x = m->x_max - candidate->x;
	if (m->invert_y)
		candidate->y = m->y_max - candidate->y;
	if (m->quality_full_scale) {
		uint64_t scaled = energy >= m->quality_full_scale ? 1000 :
			energy * 1000 / m->quality_full_scale;
		candidate->quality = (uint16_t)scaled;
	} else {
		candidate->quality = 1000;
	}
	return 0;
}

static int32_t g6_scale_center(unsigned int center, int64_t multiplier,
			       int64_t offset, int32_t maximum)
{
	int64_t scaled = multiplier * center + offset;

	if (scaled <= 0)
		return 0;
	scaled = (scaled + 50000) / 100000;
	if (scaled > maximum)
		return maximum;
	return (int32_t)scaled;
}

static void g6_index_hysteresis_reset(struct g6_processor *processor)
{
	memset(processor->index_hyst, 0, sizeof(processor->index_hyst));
}

static uint8_t g6_index_stable(struct g6_index_hysteresis *h, uint8_t raw,
			       uint32_t raw_energy,
			       const uint32_t energy_by_center[256],
			       unsigned int frames,
			       uint32_t margin_permille)
{
	uint32_t challenger_energy = energy_by_center[raw];
	uint32_t incumbent_energy;

	(void)raw_energy;
	if (!h->valid) {
		h->selected = raw;
		h->valid = true;
		h->pending = 0;
		h->pending_cycles = 0;
		return h->selected;
	}
	if (raw == h->selected) {
		h->pending = 0;
		h->pending_cycles = 0;
		return h->selected;
	}

	incumbent_energy = energy_by_center[h->selected];
	if (!incumbent_energy ||
	    (uint64_t)challenger_energy * 1000 >=
		(uint64_t)incumbent_energy * margin_permille) {
		h->selected = raw;
		h->pending = 0;
		h->pending_cycles = 0;
		return h->selected;
	}

	if (h->pending == raw) {
		h->pending_cycles++;
	} else {
		h->pending = raw;
		h->pending_cycles = 1;
	}
	if (h->pending_cycles >= frames) {
		h->selected = raw;
		h->pending = 0;
		h->pending_cycles = 0;
	}
	return h->selected;
}

static void g6_log_energy(const struct g6_mapping *m,
			  const uint32_t best_energy[2],
			  const uint8_t best_center[2],
			  const uint8_t trailer_valid[2],
			  const bool selected_trailer_invalid[2], bool found,
			  const struct g6_candidate *candidate)
{
	if (!m->log_energy)
		return;
	fprintf(stderr,
		"g6-pen: energy b0=%" PRIu32 " c0=%u b1=%" PRIu32
		" c1=%u fb0=%u fb1=%u tv0=%u tv1=%u found=%u present=%u"
		" quality=%u\n",
		best_energy[0], (unsigned int)best_center[0], best_energy[1],
		(unsigned int)best_center[1],
		selected_trailer_invalid[0] ? 1U : 0U,
		selected_trailer_invalid[1] ? 1U : 0U,
		(unsigned int)trailer_valid[0],
		(unsigned int)trailer_valid[1], found ? 1U : 0U,
		candidate->present ? 1U : 0U, (unsigned int)candidate->quality);
}

static int g6_decode_ff00_cycle(struct g6_processor *processor,
				struct g6_candidate *candidate)
{
	const struct g6_mapping *m = &processor->mapping;
	const struct g6_part *part = &processor->cycle.part[G6_PART_0C];
	const uint8_t *data = part->content;
	size_t section = 9, section_end, position;
	uint32_t section_length;
	uint32_t best_energy[2] = { 0, 0 };
	uint32_t center_energy[2][256] = { { 0 } };
	uint8_t best_center[2] = { 0, 0 };
	uint8_t trailer_valid[2] = { 0, 0 };
	bool selected_trailer_invalid[2] = { false, false };

	memset(candidate, 0, sizeof(*candidate));
	if (part->content_len < section + 8) {
		g6_log_energy(m, best_energy, best_center, trailer_valid,
			      selected_trailer_invalid, false, candidate);
		return -EMSGSIZE;
	}
	section_length = g6_read_le32(data + section);
	if (section_length > part->content_len - section - 4) {
		g6_log_energy(m, best_energy, best_center, trailer_valid,
			      selected_trailer_invalid, false, candidate);
		return -EPROTO;
	}
	section_end = section + 4 + section_length;
	if (g6_read_le16(data + section + 4) != 0xff00 ||
	    data[section + 6] != 0) {
		g6_log_energy(m, best_energy, best_center, trailer_valid,
			      selected_trailer_invalid, false, candidate);
		return -ENODATA;
	}

	/* header_value at section+7 is intentionally the first nested kind. */
	position = section + 7;
	while (position + 4 <= section_end) {
		uint8_t kind = data[position];
		uint16_t payload_length = g6_read_le16(data + position + 2);
		const uint8_t *payload;
		size_t next = position + 4 + payload_length;

		if (next > section_end) {
			g6_log_energy(m, best_energy, best_center, trailer_valid,
				      selected_trailer_invalid, false, candidate);
			return -EPROTO;
		}
		if (kind != 0x5c) {
			position = next;
			continue;
		}
		payload = data + position + 4;
		if (payload_length >= 12) {
			unsigned int n = payload[4], bank, vector;
			bool found[2] = { false, false };

			if (data[position + 1] != 0 || n != 8 || payload[5] != 1 ||
			    payload[6] != 1 || payload[7] != 1 ||
			    payload[9] != 6 ||
			    g6_read_le16(payload + 10) != 0xffff || !n ||
			    (size_t)payload_length != 12 + (size_t)n * 2 * 48) {
				position = next;
				continue;
			}
			for (bank = 0; bank < 2; bank++) {
				for (vector = 0; vector < n; vector++) {
					const uint8_t *entry = payload + 12 +
						(size_t)(bank * n + vector) * 48;
					uint32_t energy = g6_read_le32(entry + 4);
					uint8_t center = entry[46];
					unsigned int axis_size = bank ? 46 : 68;
					bool trailer = center >= 4 &&
						(unsigned int)center + 4 < axis_size &&
						entry[44] == center - 4 &&
						entry[45] == center + 4 &&
						entry[47] == 0;

					if (trailer)
						trailer_valid[bank]++;
					if (energy > center_energy[bank][center])
						center_energy[bank][center] = energy;
					if (energy > best_energy[bank]) {
						best_energy[bank] = energy;
						best_center[bank] = center;
						selected_trailer_invalid[bank] =
							!trailer;
					}
				}
				found[bank] = best_energy[bank] > 0;
			}
			if (!found[0] || !found[1]) {
				g6_log_energy(m, best_energy, best_center,
					      trailer_valid,
					      selected_trailer_invalid, false,
					      candidate);
				return -ENODATA;
			}
			candidate->present = best_energy[0] >= m->min_peak &&
				best_energy[1] >= m->min_peak &&
				(uint64_t)best_energy[0] + best_energy[1] >= m->min_energy &&
				(!m->min_trailer_valid ||
				 (trailer_valid[0] >= m->min_trailer_valid &&
				  trailer_valid[1] >= m->min_trailer_valid)) &&
				m->min_active_cells <= 2;
			if (!candidate->present) {
				g6_log_energy(m, best_energy, best_center,
					      trailer_valid,
					      selected_trailer_invalid, true,
						      candidate);
				return 0;
			}
			if (processor->tracking != G6_TRACK_HOVER &&
			    !processor->positive_frames)
				g6_index_hysteresis_reset(processor);
			for (bank = 0; bank < 2; bank++)
				best_center[bank] = g6_index_stable(
					&processor->index_hyst[bank],
					best_center[bank], best_energy[bank],
					center_energy[bank], G6_INDEX_FRAMES,
					G6_INDEX_MARGIN_PERMILLE);
			candidate->x = g6_scale_center(best_center[0], 40580996,
						      -13820, m->x_max);
			candidate->y = g6_scale_center(best_center[1], 40118737,
						      -20150, m->y_max);
			if (m->invert_x)
				candidate->x = m->x_max - candidate->x;
			if (m->invert_y)
				candidate->y = m->y_max - candidate->y;
			if (m->quality_full_scale) {
				uint64_t energy = (uint64_t)best_energy[0] + best_energy[1];
				candidate->quality = energy >= m->quality_full_scale ? 1000 :
					(uint16_t)(energy * 1000 / m->quality_full_scale);
			} else {
				candidate->quality = 1000;
			}
			g6_log_energy(m, best_energy, best_center, trailer_valid,
				      selected_trailer_invalid, true, candidate);
			return 0;
		}
		position = next;
	}
	g6_log_energy(m, best_energy, best_center, trailer_valid,
		      selected_trailer_invalid, false, candidate);
	return -ENODATA;
}

static int g6_decode_cycle(struct g6_processor *processor,
			   struct g6_candidate *candidate)
{
	if (!processor->mapping.hover_enabled) {
		memset(candidate, 0, sizeof(*candidate));
		return -ENODATA;
	}
	if (processor->mapping.decoder == G6_DECODER_FF00_0C_MAX_ENERGY)
		return g6_decode_ff00_cycle(processor, candidate);
	return g6_decode_rect_cycle(processor, candidate);
}

static void g6_emit(struct g6_processor *processor,
		    const struct g6_pen_state *state)
{
	processor->stats.emitted_states++;
	if (processor->emit)
		processor->emit(processor->emit_userdata, state);
}

static void g6_reset_tap(struct g6_processor *processor)
{
	processor->still_since_ns = 0;
	processor->still_ref_x = 0;
	processor->still_ref_y = 0;
	processor->still_valid = false;
}

static void g6_emit_tap(struct g6_processor *processor, uint64_t timestamp_ns)
{
	const struct g6_mapping *m = &processor->mapping;
	struct g6_pen_state state;
	uint64_t reference_ns;
	uint64_t duration_ns;

	if (!m->tap_enabled || !processor->still_valid ||
	    !processor->have_last_point)
		return;
	reference_ns = processor->last_complete_ns;
	if (!reference_ns)
		reference_ns = timestamp_ns;
	if (reference_ns > timestamp_ns)
		reference_ns = timestamp_ns;
	if (reference_ns < processor->still_since_ns)
		return;
	duration_ns = reference_ns - processor->still_since_ns;
	if (duration_ns < (uint64_t)m->tap_min_ms * UINT64_C(1000000) ||
	    duration_ns > (uint64_t)m->tap_max_ms * UINT64_C(1000000))
		return;

	if (m->log_energy)
		fprintf(stderr, "g6-pen: tap x=%" PRId32 " y=%" PRId32
			" still=%" PRIu64 "ms\n",
			processor->last_x, processor->last_y,
			duration_ns / UINT64_C(1000000));
	memset(&state, 0, sizeof(state));
	state.timestamp_ns = timestamp_ns;
	state.generation = processor->generation;
	state.valid = G6_VALID_PROXIMITY | G6_VALID_TOOL |
		      G6_VALID_POSITION | G6_VALID_PRESSURE;
	state.valid |= G6_VALID_TAP;
	state.proximity = true;
	state.tip = true;
	state.x = processor->last_x;
	state.y = processor->last_y;
	state.pressure = 1;
	g6_emit(processor, &state);
	state.tip = false;
	state.pressure = 0;
	state.valid |= G6_VALID_TAP;
	g6_emit(processor, &state);
}

static void g6_emit_lift(struct g6_processor *processor, uint64_t timestamp_ns)
{
	struct g6_pen_state state;

	if (processor->tracking != G6_TRACK_HOVER)
		return;
	g6_emit_tap(processor, timestamp_ns);
	memset(&state, 0, sizeof(state));
	state.timestamp_ns = timestamp_ns;
	state.generation = processor->generation;
	state.valid = G6_VALID_PROXIMITY | G6_VALID_TOOL;
	g6_emit(processor, &state);
	processor->tracking = G6_TRACK_CLOSED;
	processor->positive_frames = 0;
	processor->negative_frames = 0;
	processor->have_last_point = false;
	g6_reset_tap(processor);
	g6_index_hysteresis_reset(processor);
}

static struct g6_pen_state g6_hover_state(struct g6_processor *processor,
					  uint64_t timestamp_ns,
					  int32_t x, int32_t y,
					  uint16_t quality)
{
	struct g6_pen_state state;

	memset(&state, 0, sizeof(state));
	state.timestamp_ns = timestamp_ns;
	state.generation = processor->generation;
	state.valid = G6_VALID_PROXIMITY | G6_VALID_POSITION |
		      G6_VALID_TOOL | G6_VALID_QUALITY;
	state.proximity = true;
	state.x = x;
	state.y = y;
	state.quality = quality;
	return state;
}

static void g6_emit_position(struct g6_processor *processor,
			     const struct g6_candidate *candidate,
			     uint64_t timestamp_ns)
{
	struct g6_pen_state state;
	unsigned int step;

	if (!processor->have_last_point || timestamp_ns <= processor->last_point_ns) {
		state = g6_hover_state(processor, timestamp_ns, candidate->x,
				       candidate->y, candidate->quality);
		g6_emit(processor, &state);
	} else {
		uint64_t span = timestamp_ns - processor->last_point_ns;
		int64_t dx = (int64_t)candidate->x - processor->last_x;
		int64_t dy = (int64_t)candidate->y - processor->last_y;
		int32_t dq = (int32_t)candidate->quality - processor->last_quality;

		for (step = 1; step <= 4; step++) {
			state = g6_hover_state(processor,
				processor->last_point_ns + span * step / 4,
				processor->last_x + (int32_t)(dx * step / 4),
				processor->last_y + (int32_t)(dy * step / 4),
				(uint16_t)((int32_t)processor->last_quality +
					   dq * (int32_t)step / 4));
			g6_emit(processor, &state);
		}
	}
	processor->have_last_point = true;
	processor->last_x = candidate->x;
	processor->last_y = candidate->y;
	processor->last_quality = candidate->quality;
	processor->last_point_ns = timestamp_ns;
}

static void g6_track_still(struct g6_processor *processor,
			   const struct g6_candidate *candidate,
			   uint64_t timestamp_ns)
{
	uint64_t x_delta, y_delta;
	uint64_t x_limit, y_limit;

	if (!processor->still_valid) {
		processor->still_since_ns = timestamp_ns;
		processor->still_ref_x = candidate->x;
		processor->still_ref_y = candidate->y;
		processor->still_valid = true;
		return;
	}

	x_delta = candidate->x >= processor->still_ref_x ?
		(uint64_t)((int64_t)candidate->x - processor->still_ref_x) :
		(uint64_t)((int64_t)processor->still_ref_x - candidate->x);
	y_delta = candidate->y >= processor->still_ref_y ?
		(uint64_t)((int64_t)candidate->y - processor->still_ref_y) :
		(uint64_t)((int64_t)processor->still_ref_y - candidate->y);
	x_limit = (uint64_t)processor->mapping.x_max *
		processor->mapping.tap_still_delta_permille / 1000;
	y_limit = (uint64_t)processor->mapping.y_max *
		processor->mapping.tap_still_delta_permille / 1000;
	if (!x_limit)
		x_limit = 1;
	if (!y_limit)
		y_limit = 1;
	if (x_delta > x_limit || y_delta > y_limit) {
		processor->still_since_ns = timestamp_ns;
		processor->still_ref_x = candidate->x;
		processor->still_ref_y = candidate->y;
	}
}

static void g6_process_candidate(struct g6_processor *processor,
				 const struct g6_candidate *candidate,
				 uint64_t timestamp_ns)
{
	processor->last_complete_ns = timestamp_ns;
	if (!candidate->present) {
		processor->positive_frames = 0;
		if (processor->await_clear) {
			processor->await_clear = false;
			processor->tracking = G6_TRACK_CLOSED;
		}
		if (processor->tracking == G6_TRACK_HOVER) {
			processor->negative_frames++;
			if (processor->negative_frames >= processor->mapping.release_frames)
				g6_emit_lift(processor, timestamp_ns);
		} else {
			processor->negative_frames = 0;
			processor->tracking = G6_TRACK_CLOSED;
		}
		return;
	}

	processor->negative_frames = 0;
	if (processor->await_clear) {
		processor->tracking = G6_TRACK_WAIT_CLEAR;
		return;
	}
	if (processor->tracking != G6_TRACK_HOVER) {
		processor->tracking = G6_TRACK_ACQUIRING;
		processor->positive_frames++;
		if (processor->positive_frames < processor->mapping.acquire_frames)
			return;
		processor->tracking = G6_TRACK_HOVER;
		processor->have_last_point = false;
	}
	g6_track_still(processor, candidate, timestamp_ns);
	g6_emit_position(processor, candidate, timestamp_ns);
}

static void g6_process_cycle(struct g6_processor *processor)
{
	struct g6_candidate candidate;
	int result;

	processor->stats.complete_cycles++;
	result = g6_decode_cycle(processor, &candidate);
	if (!result) {
		processor->stats.decoded_cycles++;
		g6_process_candidate(processor, &candidate,
				     processor->cycle.last_timestamp_ns);
	} else if (result != -ENODATA) {
		processor->stats.invalid_records++;
	}
	g6_cycle_clear(processor, false);
}

static void g6_generation_boundary(struct g6_processor *processor,
				   uint32_t generation)
{
	g6_cycle_clear(processor, true);
	processor->stats.generation_boundaries++;
	processor->generation = generation;
	processor->generation_valid = true;
}

static void g6_sequence_boundary(struct g6_processor *processor)
{
	processor->stats.sequence_gaps++;
	g6_cycle_clear(processor, true);
}

void g6_processor_init(struct g6_processor *processor,
		       const struct g6_mapping *mapping,
		       g6_emit_fn emit, void *emit_userdata)
{
	memset(processor, 0, sizeof(*processor));
	processor->mapping = *mapping;
	processor->emit = emit;
	processor->emit_userdata = emit_userdata;
	processor->tracking = G6_TRACK_CLOSED;
}

void g6_processor_tick(struct g6_processor *processor, uint64_t now_ns)
{
	uint64_t deadline;

	if (processor->tracking != G6_TRACK_HOVER)
		return;
	deadline = processor->last_complete_ns + processor->mapping.stale_ns;
	if (deadline < processor->last_complete_ns)
		deadline = UINT64_MAX;
	if (now_ns >= deadline) {
		g6_emit_lift(processor, deadline);
		processor->stats.stale_lifts++;
	}
}

int g6_processor_feed(struct g6_processor *processor,
		      const struct g6_record *record)
{
	struct g6_part *part;
	bool generation_changed = false;
	int index;

	if (!processor || !record || record->content_len > G6_HEAT_MAX_CONTENT ||
	    (record->content_len && !record->content))
		return -EINVAL;
	processor->stats.records++;
	g6_processor_tick(processor, record->timestamp_ns);
	if (processor->sequence_valid &&
	    record->sequence != processor->last_sequence + UINT32_C(1))
		g6_sequence_boundary(processor);
	processor->last_sequence = record->sequence;
	processor->sequence_valid = true;

	if (!processor->generation_valid) {
		processor->generation = record->generation;
		processor->generation_valid = true;
	} else if (record->generation != processor->generation) {
		g6_generation_boundary(processor, record->generation);
		generation_changed = true;
	}
	if (record->flags & G6_HEAT_F_BOUNDARY) {
		if (!generation_changed)
			g6_generation_boundary(processor, record->generation);
		return 0;
	}
	if (record->report_id == 0x07 || record->report_id == 0x6e) {
		processor->stats.sideband_records++;
		return 0;
	}

	index = g6_part_index(&processor->cycle, record->report_id);
	if (index < 0) {
		processor->stats.invalid_records++;
		return -ENOMSG;
	}
	if (record->report_id == 0x0c) {
		if (g6_cycle_count(&processor->cycle))
			g6_cycle_clear(processor, true);
		index = G6_PART_0C;
	} else if (!processor->cycle.part[G6_PART_0C].present) {
		processor->stats.unanchored_records++;
		return 0;
	}
	if (record->report_id != 0x0c &&
	    record->timestamp_ns > processor->cycle.first_timestamp_ns &&
	    record->timestamp_ns - processor->cycle.first_timestamp_ns >
		G6_CYCLE_WINDOW_NS) {
		g6_cycle_clear(processor, true);
		processor->stats.unanchored_records++;
		return 0;
	}
	if (processor->cycle.part[index].present) {
		g6_cycle_clear(processor, true);
		processor->stats.unanchored_records++;
		return 0;
	}

	part = &processor->cycle.part[index];
	part->present = true;
	part->report_id = record->report_id;
	part->content_len = record->content_len;
	part->timestamp_ns = record->timestamp_ns;
	if (record->content_len)
		memcpy(part->content, record->content, record->content_len);
	if (record->report_id == 0x0c)
		processor->cycle.first_timestamp_ns = record->timestamp_ns;
	processor->cycle.last_timestamp_ns = record->timestamp_ns;
	processor->cycle.generation = record->generation;
	if (g6_cycle_complete(&processor->cycle))
		g6_process_cycle(processor);
	return 0;
}

void g6_processor_finish(struct g6_processor *processor, uint64_t timestamp_ns)
{
	g6_emit_lift(processor, timestamp_ns);
	g6_cycle_clear(processor, true);
}

void g6_pacer_init(struct g6_pacer *pacer, uint64_t interval_ns)
{
	memset(pacer, 0, sizeof(*pacer));
	pacer->interval_ns = interval_ns;
}

void g6_pacer_cancel(struct g6_pacer *pacer)
{
	pacer->drops += pacer->count;
	pacer->head = 0;
	pacer->count = 0;
	pacer->last_due_ns = 0;
}

void g6_pacer_enqueue(struct g6_pacer *pacer,
		      const struct g6_pen_state *state, uint64_t now_ns)
{
	uint64_t due = now_ns;
	unsigned int index;

	if (pacer->count == G6_PACER_MAX_STATES)
		g6_pacer_cancel(pacer);
	if (pacer->last_due_ns &&
	    pacer->last_due_ns <= UINT64_MAX - pacer->interval_ns &&
	    pacer->last_due_ns + pacer->interval_ns > now_ns)
		due = pacer->last_due_ns + pacer->interval_ns;
	index = (pacer->head + pacer->count) % G6_PACER_MAX_STATES;
	pacer->pending[index].state = *state;
	pacer->pending[index].due_ns = due;
	pacer->count++;
	pacer->last_due_ns = due;
}

bool g6_pacer_pop_due(struct g6_pacer *pacer, uint64_t now_ns,
		      struct g6_pen_state *state)
{
	if (!pacer->count || pacer->pending[pacer->head].due_ns > now_ns)
		return false;
	*state = pacer->pending[pacer->head].state;
	pacer->head = (pacer->head + 1) % G6_PACER_MAX_STATES;
	pacer->count--;
	return true;
}

uint64_t g6_pacer_wait_ns(const struct g6_pacer *pacer, uint64_t now_ns,
			  uint64_t maximum_ns)
{
	uint64_t due;

	if (!pacer->count)
		return maximum_ns;
	due = pacer->pending[pacer->head].due_ns;
	if (due <= now_ns)
		return 0;
	if (due - now_ns < maximum_ns)
		return due - now_ns;
	return maximum_ns;
}
