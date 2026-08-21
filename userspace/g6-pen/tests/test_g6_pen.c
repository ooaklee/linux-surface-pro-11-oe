#include "g6_pen.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct capture {
	struct g6_pen_state state[64];
	unsigned int count;
};

static void capture_state(void *userdata, const struct g6_pen_state *state)
{
	struct capture *capture = userdata;

	assert(capture->count < 64);
	capture->state[capture->count++] = *state;
}

static struct g6_mapping test_mapping(void)
{
	struct g6_mapping mapping;
	char error[128];

	g6_mapping_defaults(&mapping);
	mapping.hover_enabled = true;
	mapping.report_id = 0x0b;
	mapping.report_instance = 1;
	mapping.offset = 0;
	mapping.rows = 2;
	mapping.columns = 2;
	mapping.row_stride = 4;
	mapping.sample_stride = 2;
	mapping.sample_format = G6_SAMPLE_U16_LE;
	mapping.baseline = 0;
	mapping.polarity = G6_POLARITY_POSITIVE;
	mapping.cell_threshold = 10;
	mapping.min_peak = 50;
	mapping.min_energy = 50;
	mapping.min_active_cells = 1;
	mapping.quality_full_scale = 100;
	mapping.acquire_frames = 1;
	mapping.release_frames = 2;
	assert(!g6_mapping_validate(&mapping, error, sizeof(error)));
	return mapping;
}

static void feed_record(struct g6_processor *processor, uint32_t generation,
			uint64_t timestamp, uint32_t sequence, uint8_t report_id,
			uint8_t flags, const uint8_t *content, uint16_t content_len)
{
	struct g6_record record = {
		.generation = generation,
		.timestamp_ns = timestamp,
		.sequence = sequence,
		.content_len = content_len,
		.report_id = report_id,
		.flags = flags,
		.content = content,
	};
	int result = g6_processor_feed(processor, &record);

	assert(!result || result == -ENOMSG);
}

static uint64_t feed_cycle(struct g6_processor *processor, uint32_t generation,
			   uint64_t start, uint32_t *sequence,
			   const uint8_t order[5], const uint8_t grid[8])
{
	uint8_t dummy = 0;
	unsigned int i, seen_0b = 0;

	for (i = 0; i < 5; i++) {
		const uint8_t *payload = &dummy;
		uint16_t length = 1;

		if (order[i] == 0x0b && seen_0b++ == 1) {
			payload = grid;
			length = 8;
		}
		feed_record(processor, generation, start + i * UINT64_C(1000000),
			    (*sequence)++, order[i], 0, payload, length);
	}
	return start + UINT64_C(4000000);
}

static void test_abi(void)
{
	uint8_t wire[G6_HEAT_MAX_RECORD], payload[] = { 0xaa, 0x55, 0x10 };
	struct g6_record input = {
		.generation = 7,
		.timestamp_ns = UINT64_C(1234567890123),
		.sequence = 99,
		.content_len = sizeof(payload),
		.report_id = 0x0b,
		.content = payload,
	};
	struct g6_record output;
	char error[128];
	size_t length;

	length = g6_record_encode(wire, sizeof(wire), &input);
	assert(length == G6_HEAT_HEADER_LEN + sizeof(payload));
	assert(!g6_record_decode(wire, length, &output, error, sizeof(error)));
	assert(output.generation == input.generation);
	assert(output.timestamp_ns == input.timestamp_ns);
	assert(output.sequence == input.sequence);
	assert(output.report_id == input.report_id);
	assert(output.content_len == sizeof(payload));
	assert(!memcmp(output.content, payload, sizeof(payload)));
	wire[0] ^= 1;
	assert(g6_record_decode(wire, length, &output, error, sizeof(error)) == -EPROTO);
}

static void test_order_variations(void)
{
	static const uint8_t variations[6][5] = {
		{ 0x0c, 0x0b, 0x1a, 0x0d, 0x0b },
		{ 0x0c, 0x0b, 0x1a, 0x0b, 0x0d },
		{ 0x0c, 0x1a, 0x0b, 0x0d, 0x0b },
		{ 0x0c, 0x1a, 0x0b, 0x0b, 0x0d },
		{ 0x0c, 0x0b, 0x0d, 0x1a, 0x0b },
		{ 0x0c, 0x0b, 0x0d, 0x0b, 0x1a },
	};
	const uint8_t grid[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	struct g6_mapping mapping = test_mapping();
	unsigned int variation;

	for (variation = 0; variation < 6; variation++) {
		struct g6_processor processor;
		struct capture capture = { 0 };
		uint32_t sequence = 1;

		g6_processor_init(&processor, &mapping, capture_state, &capture);
		feed_cycle(&processor, 1, UINT64_C(1000000000), &sequence,
			   variations[variation], grid);
		assert(processor.stats.complete_cycles == 1);
		assert(processor.stats.incomplete_cycles == 0);
		assert(capture.count == 1);
		assert(capture.state[0].proximity);
		assert(capture.state[0].x == 0 && capture.state[0].y == 0);
	}
}

static void test_cycle_anchor(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t grid[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	const uint8_t dummy = 0;
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_record(&processor, 1, UINT64_C(1000000000), sequence++, 0x0b, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(1001000000), sequence++, 0x1a, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(1002000000), sequence++, 0x0d, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(1003000000), sequence++, 0x0b, 0,
		    grid, 8);
	assert(processor.stats.unanchored_records == 4);
	feed_cycle(&processor, 1, UINT64_C(1015000000), &sequence, order, grid);
	assert(processor.stats.complete_cycles == 1);
	assert(capture.count == 1);

	/* Timestamp zero is valid and must still anchor the cycle window. */
	memset(&processor, 0, sizeof(processor));
	memset(&capture, 0, sizeof(capture));
	sequence = 1;
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_cycle(&processor, 1, 0, &sequence, order, grid);
	assert(processor.stats.complete_cycles == 1);
	assert(capture.count == 1);

	memset(&processor, 0, sizeof(processor));
	memset(&capture, 0, sizeof(capture));
	sequence = 1;
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_record(&processor, 1, 0, sequence++, 0x0c, 0, &dummy, 1);
	feed_record(&processor, 1, UINT64_C(31000000), sequence++, 0x0b, 0,
		    &dummy, 1);
	assert(processor.stats.incomplete_cycles == 1);
	assert(processor.stats.unanchored_records == 1);

	memset(&processor, 0, sizeof(processor));
	memset(&capture, 0, sizeof(capture));
	sequence = 1;
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_record(&processor, 1, UINT64_C(2000000000), sequence++, 0x0c, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2001000000), sequence++, 0x0b, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2002000000), sequence++, 0x0c, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2003000000), sequence++, 0x0b, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2004000000), sequence++, 0x1a, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2005000000), sequence++, 0x0d, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2006000000), sequence++, 0x0b, 0,
		    grid, 8);
	assert(processor.stats.incomplete_cycles == 1);
	assert(processor.stats.complete_cycles == 1);
	assert(capture.count == 1);
}

static void test_sequence_gap_and_wrap(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t grid[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	const uint8_t dummy = 0;
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_record(&processor, 1, UINT64_C(1000000000), UINT32_MAX, 0x07, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(1001000000), 0, 0x6e, 0,
		    &dummy, 1);
	assert(processor.stats.sequence_gaps == 0);

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_cycle(&processor, 1, UINT64_C(2000000000), &sequence, order, grid);
	assert(capture.count == 1);
	feed_record(&processor, 1, UINT64_C(2010000000), sequence + 1, 0x07, 0,
		    &dummy, 1);
	sequence += 2;
	assert(processor.stats.sequence_gaps == 1);
	assert(capture.count == 2 && !capture.state[1].proximity);
	feed_record(&processor, 1, UINT64_C(2020000000), sequence++, 0x0c, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2021000000), sequence++, 0x0b, 0,
		    &dummy, 1);
	sequence++;
	feed_record(&processor, 1, UINT64_C(2022000000), sequence++, 0x1a, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2023000000), sequence++, 0x0d, 0,
		    &dummy, 1);
	feed_record(&processor, 1, UINT64_C(2024000000), sequence++, 0x0b, 0,
		    grid, 8);
	assert(processor.stats.sequence_gaps == 2);
	assert(processor.stats.incomplete_cycles == 1);
	assert(processor.stats.complete_cycles == 1);
}

static void test_interpolation_and_release(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t top_left[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	const uint8_t bottom_right[8] = { 0, 0, 0, 0, 0, 0, 100, 0 };
	const uint8_t absent[8] = { 0 };
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_cycle(&processor, 1, UINT64_C(1000000000), &sequence, order, top_left);
	feed_cycle(&processor, 1, UINT64_C(1015000000), &sequence, order, bottom_right);
	assert(capture.count == 5);
	assert(capture.state[1].x == mapping.x_max / 4);
	assert(capture.state[4].x == mapping.x_max);
	assert(capture.state[4].y == mapping.y_max);
	feed_cycle(&processor, 1, UINT64_C(1030000000), &sequence, order, absent);
	assert(capture.count == 5);
	feed_cycle(&processor, 1, UINT64_C(1045000000), &sequence, order, absent);
	assert(capture.count == 6);
	assert(!capture.state[5].proximity);
}

static void test_generation_inhibit(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t present[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	const uint8_t absent[8] = { 0 };
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	feed_cycle(&processor, 1, UINT64_C(1000000000), &sequence, order, present);
	assert(capture.count == 1);
	feed_record(&processor, 2, UINT64_C(1010000000), sequence++, 0,
		    G6_HEAT_F_RESET, NULL, 0);
	assert(capture.count == 2 && !capture.state[1].proximity);
	feed_cycle(&processor, 2, UINT64_C(1020000000), &sequence, order, present);
	feed_cycle(&processor, 2, UINT64_C(1035000000), &sequence, order, present);
	assert(capture.count == 2);
	feed_cycle(&processor, 2, UINT64_C(1050000000), &sequence, order, absent);
	feed_cycle(&processor, 2, UINT64_C(1065000000), &sequence, order, present);
	assert(capture.count == 3 && capture.state[2].proximity);
}

static void test_stale_lift(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t present[8] = { 100, 0, 0, 0, 0, 0, 0, 0 };
	const uint8_t dummy = 0;
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;
	uint64_t last;

	g6_processor_init(&processor, &mapping, capture_state, &capture);
	last = feed_cycle(&processor, 1, UINT64_C(1000000000), &sequence,
			  order, present);
	g6_processor_tick(&processor, last + mapping.stale_ns - 1);
	assert(capture.count == 1);
	g6_processor_tick(&processor, last + mapping.stale_ns);
	assert(capture.count == 2 && !capture.state[1].proximity);
	assert(capture.state[1].timestamp_ns == last + mapping.stale_ns);
	assert(processor.stats.stale_lifts == 1);

	/* Zero is a valid replay time, not an unset last-complete sentinel. */
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	for (unsigned int i = 0, seen_0b = 0; i < 5; i++) {
		const uint8_t *payload = &dummy;
		uint16_t length = 1;

		if (order[i] == 0x0b && seen_0b++ == 1) {
			payload = present;
			length = (uint16_t)sizeof(present);
		}
		feed_record(&processor, 1, 0, sequence++, order[i], 0,
			    payload, length);
	}
	assert(capture.count == 1 && capture.state[0].proximity);
	g6_processor_tick(&processor, mapping.stale_ns - 1);
	assert(capture.count == 1);
	g6_processor_tick(&processor, mapping.stale_ns);
	assert(capture.count == 2 && !capture.state[1].proximity);
}

static void put_le16(uint8_t *data, uint16_t value)
{
	data[0] = (uint8_t)value;
	data[1] = (uint8_t)(value >> 8);
}

static void put_le32(uint8_t *data, uint32_t value)
{
	data[0] = (uint8_t)value;
	data[1] = (uint8_t)(value >> 8);
	data[2] = (uint8_t)(value >> 16);
	data[3] = (uint8_t)(value >> 24);
}

static void feed_ff00_cycle(struct g6_processor *processor, uint32_t generation,
			    uint64_t start, uint32_t *sequence,
			    const uint8_t *content, uint16_t content_len)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t dummy = 0;
	unsigned int i;

	for (i = 0; i < 5; i++)
		feed_record(processor, generation,
			    start + i * UINT64_C(1000000), (*sequence)++,
			    order[i], 0, order[i] == 0x0c ? content : &dummy,
			    order[i] == 0x0c ? content_len : 1);
}

static void test_ff00_coarse_decoder(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	const uint8_t observed_modes[] = { 1, 3, 4 };
	uint8_t content[801] = { 0 }, dummy = 0;
	struct g6_mapping mapping = test_mapping();
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;
	unsigned int i, mode_index;
	char error[128];

	/* One FF00 section, one exact 0x5c record, N=8 (eight per bank). */
	put_le32(content + 9, 787);
	put_le16(content + 13, 0xff00);
	content[16] = 0x5c;
	put_le16(content + 18, 780);
	content[24] = 8;
	content[25] = 1;
	content[26] = 1;
	content[27] = 1;
	content[29] = 6;
	put_le16(content + 30, 0xffff);
	put_le32(content + 36, 100);
	content[76] = 6;
	content[77] = 14;
	content[78] = 10;
	put_le32(content + 420, 120);
	content[460] = 16;
	content[461] = 24;
	content[462] = 20;

	mapping.decoder = G6_DECODER_FF00_0C_MAX_ENERGY;
	mapping.report_id = 0x0c;
	mapping.report_instance = 0;
	mapping.min_peak = 50;
	mapping.min_energy = 200;
	mapping.min_active_cells = 2;
	assert(!g6_mapping_validate(&mapping, error, sizeof(error)));
	mapping.min_active_cells = 3;
	assert(g6_mapping_validate(&mapping, error, sizeof(error)) == -EINVAL);
	mapping.min_active_cells = 2;
	for (mode_index = 0;
	     mode_index < sizeof(observed_modes) / sizeof(observed_modes[0]);
	     mode_index++) {
		content[28] = observed_modes[mode_index];
		memset(&capture, 0, sizeof(capture));
		g6_processor_init(&processor, &mapping, capture_state, &capture);
		sequence = 1;
		for (i = 0; i < 5; i++)
			feed_record(&processor, 1,
				    UINT64_C(1000000000) + i * UINT64_C(1000000),
				    sequence++, order[i], 0,
				    order[i] == 0x0c ? content : &dummy,
				    order[i] == 0x0c ? (uint16_t)sizeof(content) : 1);
		assert(capture.count == 1);
		assert(capture.state[0].x == 4058);
		assert(capture.state[0].y == 8024);
	}

	/* A malformed trailer must never become a position/presence candidate. */
	content[463] = 1;
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	for (i = 0; i < 5; i++)
		feed_record(&processor, 1, UINT64_C(2000000000) + i * UINT64_C(1000000),
			    sequence++, order[i], 0,
			    order[i] == 0x0c ? content : &dummy,
			    order[i] == 0x0c ? (uint16_t)sizeof(content) : 1);
	assert(capture.count == 0);

	/* Truncating the exact vector payload shape is rejected too. */
	content[463] = 0;
	put_le16(content + 18, 779);
	put_le32(content + 9, 786);
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	for (i = 0; i < 5; i++)
		feed_record(&processor, 1, UINT64_C(4500000000) + i * UINT64_C(1000000),
			    sequence++, order[i], 0,
			    order[i] == 0x0c ? content : &dummy,
			    order[i] == 0x0c ? (uint16_t)sizeof(content) : 1);
	assert(capture.count == 0);

	/* A wrap-consistent edge trailer is invalid: the 9-node window must fit. */
	put_le16(content + 18, 780);
	put_le32(content + 9, 787);
	content[76] = 254;
	content[77] = 6;
	content[78] = 2;
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	for (i = 0; i < 5; i++)
		feed_record(&processor, 1, UINT64_C(3000000000) + i * UINT64_C(1000000),
			    sequence++, order[i], 0,
			    order[i] == 0x0c ? content : &dummy,
			    order[i] == 0x0c ? (uint16_t)sizeof(content) : 1);
	assert(capture.count == 0);

	/* The observed 0x5c shape has no trailing vector payload bytes. */
	content[76] = 6;
	content[77] = 14;
	content[78] = 10;
	put_le16(content + 18, 781);
	put_le32(content + 9, 788);
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	for (i = 0; i < 5; i++)
		feed_record(&processor, 1, UINT64_C(4000000000) + i * UINT64_C(1000000),
			    sequence++, order[i], 0,
			    order[i] == 0x0c ? content : &dummy,
			    order[i] == 0x0c ? (uint16_t)sizeof(content) : 1);
	assert(capture.count == 0);

	/* Malformed structure cannot satisfy the post-boundary clear gate. */
	put_le16(content + 18, 780);
	put_le32(content + 9, 787);
	content[463] = 0;
	put_le32(content + 36, 100);
	put_le32(content + 420, 120);
	memset(&capture, 0, sizeof(capture));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	sequence = 1;
	feed_ff00_cycle(&processor, 1, UINT64_C(5000000000), &sequence,
			 content, (uint16_t)sizeof(content));
	assert(capture.count == 1 && capture.state[0].proximity);
	feed_record(&processor, 2, UINT64_C(5010000000), sequence++, 0,
		    G6_HEAT_F_TRANSPORT_FAULT, NULL, 0);
	assert(capture.count == 2 && !capture.state[1].proximity);
	assert(processor.await_clear);

	content[463] = 1;
	feed_ff00_cycle(&processor, 2, UINT64_C(5015000000), &sequence,
			 content, (uint16_t)sizeof(content));
	assert(processor.await_clear && capture.count == 2);
	content[463] = 0;
	feed_ff00_cycle(&processor, 2, UINT64_C(5030000000), &sequence,
			 content, (uint16_t)sizeof(content));
	assert(processor.await_clear && capture.count == 2);

	put_le32(content + 36, 0);
	put_le32(content + 420, 0);
	feed_ff00_cycle(&processor, 2, UINT64_C(5045000000), &sequence,
			 content, (uint16_t)sizeof(content));
	assert(!processor.await_clear && capture.count == 2);
	put_le32(content + 36, 100);
	put_le32(content + 420, 120);
	feed_ff00_cycle(&processor, 2, UINT64_C(5060000000), &sequence,
			 content, (uint16_t)sizeof(content));
	assert(capture.count == 3 && capture.state[2].proximity);
}

static void test_pacer(void)
{
	struct g6_pacer pacer;
	struct g6_pen_state input = { .proximity = true };
	struct g6_pen_state output;
	unsigned int i;

	g6_pacer_init(&pacer, 100);
	for (i = 0; i < 4; i++) {
		input.x = (int32_t)i;
		g6_pacer_enqueue(&pacer, &input, 1000);
	}
	assert(g6_pacer_wait_ns(&pacer, 999, 500) == 1);
	assert(g6_pacer_pop_due(&pacer, 1000, &output) && output.x == 0);
	assert(!g6_pacer_pop_due(&pacer, 1099, &output));
	assert(g6_pacer_pop_due(&pacer, 1100, &output) && output.x == 1);
	g6_pacer_cancel(&pacer);
	assert(pacer.count == 0 && pacer.drops == 2);

	g6_pacer_init(&pacer, 100);
	for (i = 0; i <= G6_PACER_MAX_STATES; i++) {
		input.x = (int32_t)i;
		g6_pacer_enqueue(&pacer, &input, 2000);
	}
	assert(pacer.count == 1);
	assert(pacer.drops == G6_PACER_MAX_STATES);
	assert(g6_pacer_pop_due(&pacer, 2000, &output));
	assert(output.x == G6_PACER_MAX_STATES);

	/* Simulate a continuously readable input loop that drains due output first. */
	g6_pacer_init(&pacer, 100);
	input.x = 0;
	g6_pacer_enqueue(&pacer, &input, 3000);
	for (i = 1; i <= G6_PACER_MAX_STATES * 2; i++) {
		assert(g6_pacer_pop_due(&pacer, 3000 + (uint64_t)i * 100,
					&output));
		assert(output.x == (int32_t)i - 1);
		input.x = (int32_t)i;
		g6_pacer_enqueue(&pacer, &input, 3000 + (uint64_t)i * 100);
	}
	assert(pacer.count == 1 && pacer.drops == 0);
}

static void test_config_overflow(void)
{
	static const char bad_config[] =
		"hover.enabled=false\n"
		"map.report_id=0x100\n";
	static const char negative_config[] =
		"hover.enabled=false\n"
		"map.min_energy=-1\n";
	char path[] = "/tmp/g6-pen-config.XXXXXX";
	char error[160];
	struct g6_mapping mapping;
	int fd = mkstemp(path);
	ssize_t written;

	assert(fd >= 0);
	written = write(fd, bad_config, sizeof(bad_config) - 1);
	assert(written == (ssize_t)(sizeof(bad_config) - 1));
	assert(!close(fd));
	g6_mapping_defaults(&mapping);
	assert(g6_mapping_load(&mapping, path, error, sizeof(error)) == -ERANGE);

	fd = open(path, O_WRONLY | O_TRUNC);
	assert(fd >= 0);
	written = write(fd, negative_config, sizeof(negative_config) - 1);
	assert(written == (ssize_t)(sizeof(negative_config) - 1));
	assert(!close(fd));
	g6_mapping_defaults(&mapping);
	assert(g6_mapping_load(&mapping, path, error, sizeof(error)) == -EINVAL);
	assert(!unlink(path));

	mapping = test_mapping();
	mapping.sample_stride = SIZE_MAX;
	assert(g6_mapping_validate(&mapping, error, sizeof(error)) == -ERANGE);
}

static void test_rect_mul_div_overflow(void)
{
	const uint8_t order[5] = { 0x0c, 0x0b, 0x1a, 0x0d, 0x0b };
	uint8_t samples[4000], dummy = 0;
	struct g6_mapping mapping;
	struct g6_processor processor;
	struct capture capture = { 0 };
	uint32_t sequence = 1;
	unsigned int i, seen_0b = 0;
	char error[160];

	memset(samples, 0xff, sizeof(samples));
	g6_mapping_defaults(&mapping);
	mapping.hover_enabled = true;
	mapping.rows = 1;
	mapping.columns = 2000;
	mapping.row_stride = sizeof(samples);
	mapping.sample_stride = 2;
	mapping.sample_format = G6_SAMPLE_U16_LE;
	mapping.baseline = INT32_MIN;
	mapping.polarity = G6_POLARITY_POSITIVE;
	mapping.cell_threshold = 1;
	mapping.min_peak = 1;
	mapping.min_energy = 1;
	mapping.min_active_cells = 1;
	mapping.x_max = INT32_MAX;
	mapping.acquire_frames = 1;
	assert(!g6_mapping_validate(&mapping, error, sizeof(error)));
	g6_processor_init(&processor, &mapping, capture_state, &capture);
	for (i = 0; i < 5; i++) {
		const uint8_t *payload = &dummy;
		uint16_t length = 1;

		if (order[i] == 0x0b && seen_0b++ == 1) {
			payload = samples;
			length = (uint16_t)sizeof(samples);
		}
		feed_record(&processor, 1, UINT64_C(5000000000) + i * UINT64_C(1000000),
			    sequence++, order[i], 0, payload, length);
	}
	assert(capture.count == 1);
	assert(capture.state[0].x >= INT32_MAX / 2 - 1);
	assert(capture.state[0].x <= INT32_MAX / 2 + 1);
}

int main(void)
{
	test_abi();
	test_order_variations();
	test_cycle_anchor();
	test_sequence_gap_and_wrap();
	test_interpolation_and_release();
	test_generation_inhibit();
	test_stale_lift();
	test_ff00_coarse_decoder();
	test_pacer();
	test_config_overflow();
	test_rect_mul_div_overflow();
	puts("g6-pen core tests: PASS");
	return 0;
}
