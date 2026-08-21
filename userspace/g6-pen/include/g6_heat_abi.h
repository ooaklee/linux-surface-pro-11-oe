#ifndef G6_HEAT_ABI_H
#define G6_HEAT_ABI_H

#include <stdint.h>

#define G6_HEAT_MAGIC              UINT32_C(0x31483647)
#define G6_HEAT_ABI_VERSION        UINT16_C(1)
#define G6_HEAT_HEADER_LEN         UINT16_C(32)
#define G6_HEAT_MAX_CONTENT        UINT16_C(4349)
#define G6_HEAT_MAX_RECORD         (G6_HEAT_HEADER_LEN + G6_HEAT_MAX_CONTENT)

#define G6_HEAT_F_RESET            UINT8_C(0x01)
#define G6_HEAT_F_SUSPEND          UINT8_C(0x02)
#define G6_HEAT_F_TRANSPORT_FAULT  UINT8_C(0x04)
#define G6_HEAT_F_BOUNDARY         (G6_HEAT_F_RESET | G6_HEAT_F_SUSPEND | \
				    G6_HEAT_F_TRANSPORT_FAULT)

/*
 * On-wire header for one /dev/g6ts-heat record.  Every multibyte member is
 * little-endian, regardless of host byte order.  Consumers should use the
 * byte-wise decoder instead of dereferencing packed members directly.
 */
struct g6_heat_header_wire {
	uint32_t magic_le;
	uint16_t abi_version_le;
	uint16_t header_len_le;
	uint32_t record_len_le;
	uint32_t generation_le;
	uint64_t timestamp_ns_le;
	uint32_t sequence_le;
	uint16_t content_len_le;
	uint8_t report_id;
	uint8_t flags;
} __attribute__((packed));

_Static_assert(sizeof(struct g6_heat_header_wire) == G6_HEAT_HEADER_LEN,
	       "g6 heat ABI header size changed");

struct g6_heat_info_wire {
	uint16_t abi_version_le;
	uint16_t struct_size_le;
	uint16_t record_header_size_le;
	uint16_t reserved0;
	uint32_t max_content_size_le;
	uint32_t queue_capacity_le;
	uint64_t supported_record_flags_le;
	uint64_t reserved[3];
} __attribute__((packed));

struct g6_heat_stats_wire {
	uint16_t abi_version_le;
	uint16_t struct_size_le;
	uint32_t generation_le;
	uint32_t queued_records_le;
	uint32_t queue_capacity_le;
	uint64_t records_enqueued_le;
	uint64_t records_dropped_le;
	uint64_t queue_flushes_le;
	uint64_t oversize_drops_le;
	uint64_t report_0b_le;
	uint64_t report_0c_le;
	uint64_t report_0d_le;
	uint64_t report_1a_le;
	uint64_t reserved[4];
} __attribute__((packed));

_Static_assert(sizeof(struct g6_heat_info_wire) == 48,
	       "g6 heat info ABI size changed");
_Static_assert(sizeof(struct g6_heat_stats_wire) == 112,
	       "g6 heat stats ABI size changed");

#ifdef __linux__
#include <sys/ioctl.h>
#define G6_HEAT_IOC_GET_INFO  _IOR('G', 0x00, struct g6_heat_info_wire)
#define G6_HEAT_IOC_GET_STATS _IOR('G', 0x01, struct g6_heat_stats_wire)
#endif

#endif
