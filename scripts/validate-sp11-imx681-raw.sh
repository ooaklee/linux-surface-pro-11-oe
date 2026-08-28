#!/usr/bin/env bash
# Exercise the non-persistent SP11 IMX681 raw path after booting the v14
# integration kernel. This script deliberately uses only Media Controller and
# V4L2 ioctls. It never reads camera MMIO, whether the stream is active or not.

set -euo pipefail

LC_ALL=C
export LC_ALL
umask 077

readonly DEFAULT_EXPECTED_RELEASE="7.2.0-jg-0sp11v14-qcom-x1e"
readonly PHY_ENTITY="msm_csiphy2"
readonly CSID_ENTITY="msm_csid0"
readonly VFE_ENTITY="msm_vfe0_rdi0"
readonly SENSOR_WIDTH=3844
readonly OUTPUT_WIDTH=3840
readonly FRAME_HEIGHT=2640
readonly EXPECTED_BYTES_PER_LINE=4800
readonly EXPECTED_BYTES_PER_FRAME=12672000
readonly MAX_FRAME_COUNT=100

FRAME_COUNT=10
OUTPUT_PATH=""
EXPECTED_RELEASE="$DEFAULT_EXPECTED_RELEASE"
MEDIA_BUS_FORMAT=""
PIXEL_FORMAT=""
BAYER_ORDER=""

MEDIA_DEVICE=""
VIDEO_DEVICE=""
VIDEO_ENTITY=""
SENSOR_ENTITY=""
SENSOR_SOURCE_PAD=""
SENSOR_CONTROL_ENTITY=""
SENSOR_CONTROL_DEVICE=""
SELECTED_TOPOLOGY=""
KERNEL_LOG_METHOD=""

usage() {
  cat <<'EOF'
Usage: validate-sp11-imx681-raw.sh [options]

Discovers and configures this exact transient media route:

  imx681 -> msm_csiphy2 -> msm_csid0 -> msm_vfe0_rdi0 -> discovered video node

The script discovers the sensor's negotiated 10-bit Bayer order instead of
assuming one. The sensor, CSIPHY, and CSID sink use that RAW10 media-bus code at
3844x2640. The CSID source, VFE, and capture node use the hardware-cropped
3840x2640 image and the matching packed-RAW10 fourcc. At least ten complete
frames are captured, with an expected payload of 12,672,000 bytes per frame.

Options:
  --frames COUNT              Capture 10..100 frames (default: 10).
  --output FILE               Raw output path. It must not already exist.
                              Default: a private file under ${TMPDIR:-/tmp}.
  --expected-release RELEASE  Required uname -r value. Default:
                              7.2.0-jg-0sp11v14-qcom-x1e.
  -h, --help                  Show this help.

This is a runtime diagnostic. It does not install files, reload modules,
reset the media graph, write persistent configuration, or reboot. Close all
camera applications before running it. Run it with sufficient video-device
and kernel-log permissions; it never invokes sudo itself.

Safety: do not add devmem, debugfs register reads, or similar MMIO access to
this workflow. Reading the SP11 camera block while its power/clock domain is
inactive can hang the bus.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Required command '$1' is missing. Install the v4l-utils/coreutils dependency that provides it."
}

entity_names() {
  awk '
    /^- entity [0-9]+: / {
      name = $0
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      print name
    }
  '
}

topology_has_entity() {
  local topology="$1"
  local wanted="$2"

  entity_names <<<"$topology" | grep -Fqx -- "$wanted"
}

imx681_routes_to_phy() {
  local phy="$1"

  awk -v phy="$phy" '
    function entity_name(header, name) {
      name = header
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      return name
    }

    /^- entity [0-9]+: / {
      current = entity_name($0)
      source_pad = ""
      next
    }

    tolower($0) ~ /^[[:space:]]*pad[0-9]+: source/ {
      pad = $0
      sub(/^[[:space:]]*pad/, "", pad)
      sub(/:.*/, "", pad)
      source_pad = pad
      next
    }

    index($0, "-> \"" phy "\":0") &&
      index(tolower(current), "imx681") && source_pad != "" {
      print current "\t" source_pad
    }
  '
}

outgoing_entities() {
  local wanted="$1"
  local wanted_pad="$2"

  awk -v wanted="$wanted" -v wanted_pad="$wanted_pad" '
    function entity_name(header, name) {
      name = header
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      return name
    }

    /^- entity [0-9]+: / {
      current = entity_name($0)
      pad = ""
      next
    }

    /^[[:space:]]*pad[0-9]+:/ {
      pad = $0
      sub(/^[[:space:]]*pad/, "", pad)
      sub(/:.*/, "", pad)
      next
    }

    current == wanted && pad == wanted_pad && /-> "/ {
      target = $0
      sub(/^.*-> "/, "", target)
      sub(/":[0-9]+.*$/, "", target)
      print target
    }
  '
}

entity_device_node() {
  local wanted="$1"

  awk -v wanted="$wanted" '
    function entity_name(header, name) {
      name = header
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      return name
    }

    /^- entity [0-9]+: / {
      current = entity_name($0)
      next
    }

    current == wanted && /device node name / {
      node = $0
      sub(/^.*device node name /, "", node)
      print node
      exit
    }
  '
}

entity_pad_mbus_format() {
  local wanted="$1"
  local wanted_pad="$2"

  awk -v wanted="$wanted" -v wanted_pad="$wanted_pad" '
    function entity_name(header, name) {
      name = header
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      return name
    }

    /^- entity [0-9]+: / {
      current = entity_name($0)
      pad = ""
      next
    }

    /^[[:space:]]*pad[0-9]+:/ {
      pad = $0
      sub(/^[[:space:]]*pad/, "", pad)
      sub(/:.*/, "", pad)
    }

    current == wanted && pad == wanted_pad && /(^|[[:space:]])fmt:/ {
      format = $0
      sub(/^.*fmt:/, "", format)
      sub(/\/.*/, "", format)
      print format
      exit
    }
  '
}

entity_pad_full_format() {
  local wanted="$1"
  local wanted_pad="$2"

  awk -v wanted="$wanted" -v wanted_pad="$wanted_pad" '
    function entity_name(header, name) {
      name = header
      sub(/^- entity [0-9]+: /, "", name)
      sub(/ \([^)]*\)$/, "", name)
      return name
    }

    /^- entity [0-9]+: / {
      current = entity_name($0)
      pad = ""
      next
    }

    /^[[:space:]]*pad[0-9]+:/ {
      pad = $0
      sub(/^[[:space:]]*pad/, "", pad)
      sub(/:.*/, "", pad)
    }

    current == wanted && pad == wanted_pad && /(^|[[:space:]])fmt:/ {
      format = $0
      sub(/^.*fmt:/, "", format)
      sub(/[[:space:]\]].*$/, "", format)
      print format
      exit
    }
  '
}

imx681_control_entities() {
  entity_names | awk 'tolower($0) ~ /imx681/ && tolower($0) ~ /pixel_array/'
}

discover_pipeline() {
  local media=""
  local topology=""
  local video_node=""
  local match_count=0
  local -a media_nodes=()
  local -a inaccessible_media=()
  local -a failed_media_queries=()
  local -a sensor_routes=()
  local -a video_entities=()
  local -a control_entities=()
  local sensor_entity=""
  local sensor_pad=""
  local video_entity=""
  local control_entity=""
  local control_device=""
  local sensor_format=""
  local pixel_format=""
  local bayer_order=""

  shopt -s nullglob
  media_nodes=(/dev/media*)
  shopt -u nullglob
  [ "${#media_nodes[@]}" -gt 0 ] || die "No /dev/media* devices were found."

  for media in "${media_nodes[@]}"; do
    if [ ! -r "$media" ] || [ ! -w "$media" ]; then
      inaccessible_media+=("$media")
      continue
    fi

    if ! topology="$(media-ctl -d "$media" --print-topology 2>/dev/null)"; then
      failed_media_queries+=("$media")
      continue
    fi

    topology_has_entity "$topology" "$PHY_ENTITY" || continue
    topology_has_entity "$topology" "$CSID_ENTITY" || continue
    topology_has_entity "$topology" "$VFE_ENTITY" || continue

    mapfile -t sensor_routes < <(imx681_routes_to_phy "$PHY_ENTITY" <<<"$topology")
    [ "${#sensor_routes[@]}" -eq 1 ] || continue
    IFS=$'\t' read -r sensor_entity sensor_pad <<<"${sensor_routes[0]}"

    sensor_format="$(entity_pad_mbus_format "$sensor_entity" "$sensor_pad" <<<"$topology")"
    case "$sensor_format" in
      SBGGR10_1X10)
        pixel_format="pBAA"
        bayer_order="BGGR"
        ;;
      SGBRG10_1X10)
        pixel_format="pGAA"
        bayer_order="GBRG"
        ;;
      SGRBG10_1X10)
        pixel_format="pgAA"
        bayer_order="GRBG"
        ;;
      SRGGB10_1X10)
        pixel_format="pRAA"
        bayer_order="RGGB"
        ;;
      *)
        die "The linked IMX681 source reports unsupported media-bus format '${sensor_format:-unknown}'; expected one of the four packed Bayer RAW10 orders."
        ;;
    esac

    mapfile -t video_entities < <(outgoing_entities "$VFE_ENTITY" 1 <<<"$topology")
    [ "${#video_entities[@]}" -eq 1 ] || continue
    video_entity="${video_entities[0]}"
    video_node="$(entity_device_node "$video_entity" <<<"$topology")"
    case "$video_node" in
      /dev/video*)
        ;;
      *)
        continue
        ;;
    esac

    control_entity=""
    control_device=""
    mapfile -t control_entities < <(imx681_control_entities <<<"$topology")
    if [ "${#control_entities[@]}" -eq 1 ]; then
      control_entity="${control_entities[0]}"
      control_device="$(entity_device_node "$control_entity" <<<"$topology")"
    fi

    match_count=$((match_count + 1))
    MEDIA_DEVICE="$media"
    VIDEO_DEVICE="$video_node"
    VIDEO_ENTITY="$video_entity"
    SENSOR_ENTITY="$sensor_entity"
    SENSOR_SOURCE_PAD="$sensor_pad"
    SENSOR_CONTROL_ENTITY="$control_entity"
    SENSOR_CONTROL_DEVICE="$control_device"
    SELECTED_TOPOLOGY="$topology"
    MEDIA_BUS_FORMAT="$sensor_format"
    PIXEL_FORMAT="$pixel_format"
    BAYER_ORDER="$bayer_order"
  done

  if [ "$match_count" -eq 0 ] && [ "${#inaccessible_media[@]}" -gt 0 ]; then
    die "Cannot read and write media device(s): ${inaccessible_media[*]}. Grant the video-device ACL/group permission and retry."
  fi
  if [ "$match_count" -eq 0 ] && [ "${#failed_media_queries[@]}" -gt 0 ]; then
    die "media-ctl could not query device(s): ${failed_media_queries[*]}. Check device permissions and the v14 CAMSS probe log."
  fi
  [ "$match_count" -gt 0 ] || die \
    "No media device contains a bound IMX681 link to the exact $PHY_ENTITY -> $CSID_ENTITY -> $VFE_ENTITY path. Check the v14 boot and CCS probe log."
  [ "$match_count" -eq 1 ] || die \
    "Found $match_count matching IMX681 CAMSS graphs; refusing an ambiguous capture."
}

read_parameter() {
  local path="$1"
  local label="$2"
  local expected="$3"
  local actual=""

  [ -r "$path" ] || return 0
  actual="$(<"$path")"
  [ "$actual" = "$expected" ] ||
    die "$label is '$actual', expected '$expected' for the proven route. Reboot without the override."
}

select_kernel_log_method() {
  local probe=""

  if command -v journalctl >/dev/null 2>&1; then
    probe="$(journalctl -k -b -n 1 --no-pager -o short-monotonic 2>/dev/null || true)"
    if [ -n "$probe" ] && ! grep -Fq -- '-- No entries --' <<<"$probe"; then
      KERNEL_LOG_METHOD="journalctl"
      return
    fi
  fi

  if command -v dmesg >/dev/null 2>&1 &&
     dmesg --help 2>&1 | grep -q -- '--since'; then
    probe="$(dmesg --color=never 2>/dev/null || true)"
    if [ -n "$probe" ]; then
      KERNEL_LOG_METHOD="dmesg"
      return
    fi
  fi

  die "Kernel logs are not readable. Grant journal/dmesg access or rerun this diagnostic as root."
}

kernel_log_since() {
  local since="$1"

  case "$KERNEL_LOG_METHOD" in
    journalctl)
      journalctl -k -b --since "$since" --no-pager -o short-monotonic
      ;;
    dmesg)
      dmesg --color=never --since "$since"
      ;;
    *)
      return 1
      ;;
  esac
}

preflight() {
  local running_release=""
  local node=""
  local users=""
  local module=""

  running_release="$(uname -r)"
  [ "$running_release" = "$EXPECTED_RELEASE" ] || die \
    "Running kernel is '$running_release'; expected '$EXPECTED_RELEASE'. Boot the tested v14 ABI (or pass the exact intended release with --expected-release)."

  for module in ccs qcom_camss phy_qcom_mipi_csi2; do
    [ -d "/sys/module/$module" ] ||
      die "Required module '$module' is not loaded in the running kernel."
  done

  read_parameter "/sys/module/ccs/parameters/imx681_mode_skip" \
    "ccs.imx681_mode_skip" "0"
  read_parameter "/sys/module/phy_qcom_mipi_csi2/parameters/cphy_trio" \
    "phy_qcom_mipi_csi2.cphy_trio" "0"
  read_parameter "/sys/module/phy_qcom_mipi_csi2/parameters/cphy_settle" \
    "phy_qcom_mipi_csi2.cphy_settle" "0"
  read_parameter "/sys/module/phy_qcom_mipi_csi2/parameters/cphy_cdr" \
    "phy_qcom_mipi_csi2.cphy_cdr" "0"

  for node in "$MEDIA_DEVICE" "$VIDEO_DEVICE"; do
    [ -c "$node" ] || die "Discovered node '$node' is not a character device."
    [ -r "$node" ] && [ -w "$node" ] || die \
      "Need read/write permission on $node (normally via the video group or an ACL)."

    if command -v fuser >/dev/null 2>&1; then
      users="$(fuser "$node" 2>/dev/null || true)"
      [ -z "$users" ] || die \
        "$node is already in use by process(es):$users. Close browsers, PipeWire/libcamera camera clients, and retry."
    fi
  done

  select_kernel_log_method
}

prepare_outputs() {
  local output_base=""
  local output_dir=""
  local output_owner=""
  local output_mode=""
  local output_mode_value=0
  local path=""

  if [ -z "$OUTPUT_PATH" ]; then
    output_dir="$(mktemp -d "${TMPDIR:-/tmp}/sp11-imx681-raw.XXXXXXXX")"
    chmod 0700 -- "$output_dir"
    OUTPUT_PATH="$output_dir/capture.raw"
  else
    [ ! -e "$OUTPUT_PATH" ] || die "Output already exists: $OUTPUT_PATH"
    output_dir="$(dirname -- "$OUTPUT_PATH")"
    [ -d "$output_dir" ] || die "Output directory does not exist: $output_dir"
    [ -w "$output_dir" ] || die "Output directory is not writable: $output_dir"
    output_base="$(basename -- "$OUTPUT_PATH")"
    output_dir="$(realpath -e -- "$output_dir")"
    OUTPUT_PATH="$output_dir/$output_base"
  fi

  [ ! -L "$output_dir" ] || die "Refusing a symlink output directory: $output_dir"
  output_owner="$(stat -c '%u' -- "$output_dir")"
  output_mode="$(stat -c '%a' -- "$output_dir")"
  output_mode_value=$((8#$output_mode))
  if [ "$output_owner" -ne "$(id -u)" ]; then
    if [ "$output_owner" -ne 0 ] || ! ((output_mode_value & 01000)); then
      die "Output directory $output_dir is controlled by another user; choose a directory owned by the current user or a root-owned sticky directory."
    fi
  fi
  if ((output_mode_value & 0022)) && ! ((output_mode_value & 01000)); then
    die "Output directory $output_dir is group/world-writable without the sticky bit; choose a private directory."
  fi

  for path in \
    "$OUTPUT_PATH" \
    "${OUTPUT_PATH}.media-before.txt" \
    "${OUTPUT_PATH}.media-after.txt" \
    "${OUTPUT_PATH}.v4l2.log" \
    "${OUTPUT_PATH}.kernel.log" \
    "${OUTPUT_PATH}.stats.txt"; do
    if ! (set -o noclobber; : >"$path") 2>/dev/null; then
      die "Could not reserve output atomically (already exists or is unsafe): $path"
    fi
    [ -f "$path" ] && [ ! -L "$path" ] || die "Reserved output is not a regular file: $path"
    [ "$(stat -c '%u' -- "$path")" -eq "$(id -u)" ] || die "Reserved output is not owned by the current user: $path"
    chmod 0600 -- "$path"
  done

  printf '%s\n' "$SELECTED_TOPOLOGY" >"${OUTPUT_PATH}.media-before.txt"
}

set_link() {
  local source_entity="$1"
  local source_pad="$2"
  local sink_entity="$3"
  local sink_pad="$4"

  media-ctl -d "$MEDIA_DEVICE" --links \
    "\"${source_entity}\":${source_pad} -> \"${sink_entity}\":${sink_pad} [1]"
}

set_pad_format() {
  local entity="$1"
  local pad="$2"
  local width="$3"

  media-ctl -d "$MEDIA_DEVICE" --set-v4l2 \
    "\"${entity}\":${pad} [fmt:${MEDIA_BUS_FORMAT}/${width}x${FRAME_HEIGHT}]"
}

configure_pipeline() {
  echo "Configuring runtime route on $MEDIA_DEVICE:"
  echo "  negotiated Bayer order: $BAYER_ORDER ($MEDIA_BUS_FORMAT -> $PIXEL_FORMAT)"
  echo "  '$SENSOR_ENTITY':$SENSOR_SOURCE_PAD -> '$PHY_ENTITY':0"
  echo "  '$PHY_ENTITY':1 -> '$CSID_ENTITY':0"
  echo "  '$CSID_ENTITY':1 -> '$VFE_ENTITY':0 -> '$VIDEO_ENTITY' ($VIDEO_DEVICE)"

  # The sensor-to-CSIPHY link is firmware-created and immutable. Verify it by
  # discovery, but do not attempt to rewrite it. Only enable the mutable CAMSS
  # links needed by the proven path; do not reset unrelated graph links.
  set_link "$PHY_ENTITY" 1 "$CSID_ENTITY" 0
  set_link "$CSID_ENTITY" 1 "$VFE_ENTITY" 0

  set_pad_format "$SENSOR_ENTITY" "$SENSOR_SOURCE_PAD" "$SENSOR_WIDTH"
  set_pad_format "$PHY_ENTITY" 0 "$SENSOR_WIDTH"
  set_pad_format "$PHY_ENTITY" 1 "$SENSOR_WIDTH"
  set_pad_format "$CSID_ENTITY" 0 "$SENSOR_WIDTH"

  # The v14 CSID decodes the 3844-pixel input and crops four pixels in
  # hardware. Its source and everything downstream therefore use 3840.
  set_pad_format "$CSID_ENTITY" 1 "$OUTPUT_WIDTH"
  set_pad_format "$VFE_ENTITY" 0 "$OUTPUT_WIDTH"
  set_pad_format "$VFE_ENTITY" 1 "$OUTPUT_WIDTH"

  v4l2-ctl -d "$VIDEO_DEVICE" \
    --set-fmt-video="width=${OUTPUT_WIDTH},height=${FRAME_HEIGHT},pixelformat=${PIXEL_FORMAT}"
}

verify_media_format() {
  local topology="$1"
  local check=""
  local entity=""
  local pad=""
  local expected=""
  local actual=""
  local -a checks=(
    "$SENSOR_ENTITY|$SENSOR_SOURCE_PAD|${MEDIA_BUS_FORMAT}/${SENSOR_WIDTH}x${FRAME_HEIGHT}"
    "$PHY_ENTITY|0|${MEDIA_BUS_FORMAT}/${SENSOR_WIDTH}x${FRAME_HEIGHT}"
    "$PHY_ENTITY|1|${MEDIA_BUS_FORMAT}/${SENSOR_WIDTH}x${FRAME_HEIGHT}"
    "$CSID_ENTITY|0|${MEDIA_BUS_FORMAT}/${SENSOR_WIDTH}x${FRAME_HEIGHT}"
    "$CSID_ENTITY|1|${MEDIA_BUS_FORMAT}/${OUTPUT_WIDTH}x${FRAME_HEIGHT}"
    "$VFE_ENTITY|0|${MEDIA_BUS_FORMAT}/${OUTPUT_WIDTH}x${FRAME_HEIGHT}"
    "$VFE_ENTITY|1|${MEDIA_BUS_FORMAT}/${OUTPUT_WIDTH}x${FRAME_HEIGHT}"
  )

  for check in "${checks[@]}"; do
    IFS='|' read -r entity pad expected <<<"$check"
    actual="$(entity_pad_full_format "$entity" "$pad" <<<"$topology")"
    [ "$actual" = "$expected" ] || die \
      "Negotiated media format on '$entity':$pad is '${actual:-missing}', expected '$expected'."
  done

  echo "Validated the negotiated Bayer code and dimensions on every active media pad."
}

verify_video_format() {
  local report=""
  local bytes_per_line=""
  local size_image=""

  report="$(v4l2-ctl -d "$VIDEO_DEVICE" --get-fmt-video)"
  printf '%s\n' "$report"

  grep -Eq "Width/Height[[:space:]]*:[[:space:]]*${OUTPUT_WIDTH}/${FRAME_HEIGHT}" <<<"$report" ||
    die "Video node did not negotiate ${OUTPUT_WIDTH}x${FRAME_HEIGHT}."
  grep -Eq "Pixel Format[[:space:]]*:[[:space:]]*'${PIXEL_FORMAT}'" <<<"$report" ||
    die "Video node did not negotiate packed RAW10 fourcc ${PIXEL_FORMAT}."

  bytes_per_line="$(awk -F: '/Bytes per Line/ { value=$2; gsub(/[^0-9]/, "", value); print value; exit }' <<<"$report")"
  if [ -n "$bytes_per_line" ] && [ "$bytes_per_line" -ne "$EXPECTED_BYTES_PER_LINE" ]; then
    die "Negotiated bytes-per-line is $bytes_per_line; expected $EXPECTED_BYTES_PER_LINE."
  fi

  size_image="$(awk -F: '/Size Image/ { value=$2; gsub(/[^0-9]/, "", value); print value; exit }' <<<"$report")"
  if [ -n "$size_image" ] && [ "$size_image" -ne "$EXPECTED_BYTES_PER_FRAME" ]; then
    die "Negotiated sizeimage is $size_image; expected $EXPECTED_BYTES_PER_FRAME."
  fi
}

extract_nonzero_bytesused() {
  awk '
    {
      lower = tolower($0)
      if (match(lower, /bytes[ _-]*used/)) {
        tail = substr($0, RSTART + RLENGTH)
        if (match(tail, /[0-9]+/)) {
          value = substr(tail, RSTART, RLENGTH) + 0
          if (value > 0)
            print value
        }
      }
    }
  '
}

scan_capture_log() {
  local capture_log="$1"
  local -a payload_sizes=()
  local payload=""

  mapfile -t payload_sizes < <(extract_nonzero_bytesused <"$capture_log")
  if [ "${#payload_sizes[@]}" -eq 0 ]; then
    echo "v4l2-ctl did not print per-buffer bytesused; the exact aggregate file-size gate remains authoritative."
    return
  fi

  for payload in "${payload_sizes[@]}"; do
    [ "$payload" -eq "$EXPECTED_BYTES_PER_FRAME" ] || die \
      "v4l2-ctl reported bytesused=$payload; expected $EXPECTED_BYTES_PER_FRAME for every dequeued frame."
  done
  echo "Validated ${#payload_sizes[@]} non-zero v4l2-ctl bytesused report(s): $EXPECTED_BYTES_PER_FRAME bytes."
}

scan_kernel_log() {
  local kernel_log="$1"
  local camera_lines=""
  local violations=""
  local camera_pattern='camss|csid|csiphy|vfe|imx681|ccs|camera'
  local violation_pattern='fifo.*(overflow|overrun)|((overflow|overrun).*(fifo))|image[ _-]*violation|truncat(ed|ion)|stop.*(time[ _-]*out|timed out)|(time[ _-]*out|timed out).*stop|halt.*(time[ _-]*out|timed out)|(time[ _-]*out|timed out).*halt'

  camera_lines="$(grep -Ei "$camera_pattern" "$kernel_log" || true)"
  violations="$(grep -Ei "$violation_pattern" <<<"$camera_lines" || true)"

  if [ -n "$violations" ]; then
    echo "Observable camera-path kernel error(s) detected:" >&2
    printf '%s\n' "$violations" >&2
    die "Raw capture failed the emitted-error log gate."
  fi

  echo "Kernel log scan passed: no emitted camera FIFO/violation/truncation/stop-timeout message."
  echo "Evidence limit: v14 masks the CSID/VFE hardware error IRQs, so a quiet log cannot prove that hidden FIFO or image-violation status never occurred."
}

analyze_raw_content() {
  python3 - "$OUTPUT_PATH" "$EXPECTED_BYTES_PER_FRAME" "$FRAME_COUNT" >"${OUTPUT_PATH}.stats.txt" <<'PY'
import hashlib
import math
import sys

path = sys.argv[1]
frame_size = int(sys.argv[2])
frame_count = int(sys.argv[3])
groups_per_frame = frame_size // 5
sample_step = max(1, groups_per_frame // 65536)

histogram = [0] * 1024
sample_total = 0
sample_sum = 0
sample_sum_sq = 0
global_min = 1023
global_max = 0
previous_samples = None
previous_digest = None
temporal_ratios = []

print(f"file={path}")
print(f"frame_size={frame_size}")
print(f"frame_count={frame_count}")
print(f"sample_group_step={sample_step}")

with open(path, "rb") as raw:
    for frame_index in range(frame_count):
        frame = raw.read(frame_size)
        if len(frame) != frame_size:
            raise SystemExit(
                f"content gate: frame {frame_index} is short ({len(frame)} bytes)"
            )

        digest = hashlib.sha256(frame).hexdigest()
        samples = []
        for group in range(0, groups_per_frame, sample_step):
            offset = group * 5
            b0, b1, b2, b3, low = frame[offset : offset + 5]
            # V4L2 packed RAW10 stores four high bytes followed by the four
            # corresponding two-bit tails in least-pixel-first order.
            samples.extend((
                (b0 << 2) | (low & 0x03),
                (b1 << 2) | ((low >> 2) & 0x03),
                (b2 << 2) | ((low >> 4) & 0x03),
                (b3 << 2) | ((low >> 6) & 0x03),
            ))

        frame_min = min(samples)
        frame_max = max(samples)
        global_min = min(global_min, frame_min)
        global_max = max(global_max, frame_max)
        for value in samples:
            histogram[value] += 1
            sample_sum += value
            sample_sum_sq += value * value
        sample_total += len(samples)

        if previous_digest == digest:
            raise SystemExit(
                f"content gate: frames {frame_index - 1} and {frame_index} are byte-identical"
            )
        if previous_samples is not None:
            changed = sum(a != b for a, b in zip(previous_samples, samples))
            ratio = changed / len(samples)
            temporal_ratios.append(ratio)
            if changed == 0:
                raise SystemExit(
                    f"content gate: sampled pixels in frames {frame_index - 1} and {frame_index} are identical"
                )

        print(
            f"frame[{frame_index}].sha256={digest} "
            f"sample_min={frame_min} sample_max={frame_max}"
        )
        previous_samples = samples
        previous_digest = digest

    if raw.read(1):
        raise SystemExit("content gate: data remains after the expected final frame")

distinct = sum(count != 0 for count in histogram)
mean = sample_sum / sample_total
variance = max(0.0, sample_sum_sq / sample_total - mean * mean)
stddev = math.sqrt(variance)
entropy = -sum(
    (count / sample_total) * math.log2(count / sample_total)
    for count in histogram
    if count
)
minimum_temporal_change = min(temporal_ratios)

print(f"sample_count={sample_total}")
print(f"sample_min={global_min}")
print(f"sample_max={global_max}")
print(f"sample_range={global_max - global_min}")
print(f"sample_distinct_codes={distinct}")
print(f"sample_mean={mean:.3f}")
print(f"sample_stddev={stddev:.3f}")
print(f"sample_entropy_bits={entropy:.3f}")
print(f"minimum_adjacent_temporal_change={minimum_temporal_change:.6%}")

if global_max - global_min < 8:
    raise SystemExit("content gate: sampled RAW10 range is less than 8 codes")
if distinct < 8:
    raise SystemExit("content gate: fewer than 8 distinct sampled RAW10 codes")
if stddev < 1.0:
    raise SystemExit("content gate: sampled RAW10 standard deviation is below 1 code")
if entropy < 1.0:
    raise SystemExit("content gate: sampled RAW10 entropy is below 1 bit")

print("content_gate=pass")
PY

  cat "${OUTPUT_PATH}.stats.txt"
}

capture_frames() {
  local capture_timeout=$((20 + FRAME_COUNT * 2))
  local expected_total=$((EXPECTED_BYTES_PER_FRAME * FRAME_COUNT))
  local actual_total=0
  local capture_status=0
  local tee_status=0
  local log_start=""
  local -a pipeline_status=()

  log_start="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "Privacy LED visual gate: confirm OFF while idle, ON only during streaming, and OFF after success or failure."
  echo "Capturing $FRAME_COUNT frames to $OUTPUT_PATH (timeout: ${capture_timeout}s)..."

  set +e
  timeout --signal=INT --kill-after=5s "${capture_timeout}s" \
    v4l2-ctl --verbose -d "$VIDEO_DEVICE" --stream-mmap=4 \
      --stream-count="$FRAME_COUNT" --stream-to="$OUTPUT_PATH" 2>&1 |
    tee "${OUTPUT_PATH}.v4l2.log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  capture_status="${pipeline_status[0]}"
  tee_status="${pipeline_status[1]}"
  sleep 1
  kernel_log_since "$log_start" >"${OUTPUT_PATH}.kernel.log" ||
    die "Could not collect the post-capture kernel log with $KERNEL_LOG_METHOD."

  [ "$tee_status" -eq 0 ] || die "Could not write the v4l2 diagnostic log."
  # Scan even when streaming failed or produced a short file: the kernel-side
  # reason is often more actionable than v4l2-ctl's exit status.
  scan_kernel_log "${OUTPUT_PATH}.kernel.log"
  [ "$capture_status" -eq 0 ] || die \
    "v4l2-ctl capture exited with status $capture_status; inspect ${OUTPUT_PATH}.v4l2.log and ${OUTPUT_PATH}.kernel.log."

  actual_total="$(stat -c '%s' -- "$OUTPUT_PATH")"
  [ "$actual_total" -eq "$expected_total" ] || die \
    "Raw file is $actual_total bytes; $FRAME_COUNT complete frames require exactly $expected_total bytes ($EXPECTED_BYTES_PER_FRAME each)."

  scan_capture_log "${OUTPUT_PATH}.v4l2.log"
  analyze_raw_content
}

print_follow_up() {
  local renderer=""
  local preview_path="${OUTPUT_PATH}.preview.png"

  renderer="$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")/render-sp11-imx681-raw.py"

  cat <<EOF

PASS (transport-size and sampled-content gate): captured $FRAME_COUNT complete packed-RAW10 frames.
  Raw data:        $OUTPUT_PATH
  Per-frame bytes: $EXPECTED_BYTES_PER_FRAME
  V4L2 log:        ${OUTPUT_PATH}.v4l2.log
  Kernel log:      ${OUTPUT_PATH}.kernel.log
  Content stats:   ${OUTPUT_PATH}.stats.txt
  Media topology:  ${OUTPUT_PATH}.media-before.txt
                   ${OUTPUT_PATH}.media-after.txt

The aggregate byte count proves complete dequeued buffers. Sampled RAW10 range,
entropy, and adjacent-frame differences reject empty, flat, and exact duplicate
output. These checks do not prove Bayer order, good exposure, or unmasked CSID/
VFE hardware status. Inspect the decoded image and complete the repeated-stream
and control-comparison gates below before declaring the camera functional.
EOF

  if [ -x "$renderer" ]; then
    echo
    echo "Raw inspection preview (auto-discovers the saved Bayer code):"
    printf '    %q %q %q\n' "$renderer" "$OUTPUT_PATH" "$preview_path"
    echo "  Use --linear on low/high control captures when comparing brightness."
  else
    echo
    echo "Raw renderer not found beside this script: $renderer"
  fi

  echo
  echo "Manual exposure/gain follow-up:"

  if [ -n "$SENSOR_CONTROL_DEVICE" ]; then
    cat <<EOF
  Controls were dynamically located on '$SENSOR_CONTROL_ENTITY':
    v4l2-ctl -d '$SENSOR_CONTROL_DEVICE' --list-ctrls

  Use only the advertised ranges, set a low and then a high value, and rerun
  this script twice. Retain the private output paths it prints and require a
  monotonic shift in decoded mean/histogram as well as a visual difference:
    v4l2-ctl -d '$SENSOR_CONTROL_DEVICE' --set-ctrl=exposure=128,analogue_gain=0
    $0 --expected-release '$EXPECTED_RELEASE'
    v4l2-ctl -d '$SENSOR_CONTROL_DEVICE' --set-ctrl=exposure=3000,analogue_gain=192
    $0 --expected-release '$EXPECTED_RELEASE'

  In v14, gain code 0 is about 1x, 192 about 4x, and 960 about 16x.
  Exposure is a line count and is capped by the current 3177-line frame;
  inspect --list-ctrls rather than assuming a future kernel has the same cap.
EOF
  else
    cat <<'EOF'
  The IMX681 pixel-array control subdevice was not uniquely identifiable.
  Inspect the saved topology and use v4l2-ctl --list-ctrls on its discovered
  /dev/v4l-subdev node before changing standard exposure/analogue_gain.
EOF
  fi

  cat <<'EOF'

Manual privacy-LED gate (the V4L2 core owns the LED; do not poll or write GPIO):
  [ ] LED was OFF before STREAMON while the camera was idle.
  [ ] LED stayed ON for the complete capture and only while streaming.
  [ ] LED returned OFF after this successful STREAMOFF.
  [ ] LED also returns OFF after any naturally failed or aborted capture.

Treat a failed LED check as a failed camera milestone even when the raw-byte
and kernel-log gates pass. Record the observation and kernel log; do not hide
wrong polarity or stream-lifetime behavior with a GPIO daemon.

Do not use devmem, debugfs register dumps, or any other camera-MMIO reader
after streaming stops. For the next gate, repeat start/stop and suspend/resume,
then proceed to libcamera only after all raw captures remain clean.
EOF
}

main() {
  local command_name=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --frames)
        require_arg "$1" "${2:-}"
        FRAME_COUNT="$2"
        shift 2
        ;;
      --output)
        require_arg "$1" "${2:-}"
        OUTPUT_PATH="$2"
        shift 2
        ;;
      --expected-release)
        require_arg "$1" "${2:-}"
        EXPECTED_RELEASE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$FRAME_COUNT" in
    ""|*[!0-9]*|0|0*)
      die "--frames must be a base-10 integer from 10 through $MAX_FRAME_COUNT (no leading zero)."
      ;;
  esac
  [ "$FRAME_COUNT" -ge 10 ] || die "--frames must be at least 10."
  [ "$FRAME_COUNT" -le "$MAX_FRAME_COUNT" ] ||
    die "--frames must not exceed $MAX_FRAME_COUNT (one frame is $EXPECTED_BYTES_PER_FRAME bytes)."
  [ -n "$EXPECTED_RELEASE" ] || die "--expected-release must not be empty."

  for command_name in awk basename chmod date dirname grep id media-ctl mktemp python3 realpath sleep stat tee timeout uname v4l2-ctl; do
    require_command "$command_name"
  done

  discover_pipeline
  preflight
  prepare_outputs
  configure_pipeline
  verify_video_format
  media-ctl -d "$MEDIA_DEVICE" --print-topology >"${OUTPUT_PATH}.media-after.txt"
  verify_media_format "$(<"${OUTPUT_PATH}.media-after.txt")"
  capture_frames
  print_follow_up
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
