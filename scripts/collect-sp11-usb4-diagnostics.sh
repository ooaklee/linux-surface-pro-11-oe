#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail
export LC_ALL=C

usage() {
	cat <<'EOF'
Usage: collect-sp11-usb4-diagnostics.sh --out DIR --port-label LABEL [options]

Collect a passive Surface Pro 11 USB-C/USB4 topology snapshot. LABEL should
describe the physical connector, for example top or bottom.

Options:
  --phase NAME                    Capture phase. Defaults to attached.
  --expected-kernel-commit SHA    Expected full 40-character kernel source
                                  commit. Recorded as evidence; the running
                                  kernel cannot verify this value itself.
  --expected-device-tree-model MODEL
                                  Require an exact live device-tree model
                                  match before creating the output directory.
  -h, --help                      Show this help.

The output can contain hardware topology and kernel logs. This helper reads an
explicit allowlist of standard sysfs text attributes and runs named read-only
topology and log commands. It never reads raw MMIO, debugfs, firmware memory,
device registers, or dedicated EDID and persistent-ID sysfs attributes. UUID
and serial fields from boltctl are redacted before output is written. Other
command and log output may still contain identifiers; review and redact the
complete directory before sharing.
EOF
}

out_dir=""
port_label=""
phase="attached"
expected_kernel_commit="not-provided"
expected_device_tree_model="not-provided"
device_tree_model_path="/proc/device-tree/model"

while (($#)); do
	case "$1" in
	--out)
		(($# >= 2)) || { usage >&2; exit 2; }
		out_dir="$2"
		shift 2
		;;
	--port-label)
		(($# >= 2)) || { usage >&2; exit 2; }
		port_label="$2"
		shift 2
		;;
	--phase)
		(($# >= 2)) || { usage >&2; exit 2; }
		phase="$2"
		shift 2
		;;
	--expected-kernel-commit)
		(($# >= 2)) || { usage >&2; exit 2; }
		expected_kernel_commit="$2"
		shift 2
		;;
	--expected-device-tree-model)
		(($# >= 2)) || { usage >&2; exit 2; }
		expected_device_tree_model="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'error: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[[ -n "$out_dir" ]] || { printf 'error: --out is required\n' >&2; exit 2; }
[[ -n "$port_label" ]] || { printf 'error: --port-label is required\n' >&2; exit 2; }
[[ "$port_label" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'error: --port-label must contain only letters, digits, dot, underscore, or dash\n' >&2
	exit 2
}
[[ "$phase" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'error: --phase must contain only letters, digits, dot, underscore, or dash\n' >&2
	exit 2
}
if [[ "$expected_kernel_commit" != "not-provided" &&
	! "$expected_kernel_commit" =~ ^[0-9A-Fa-f]{40}$ ]]; then
	printf 'error: --expected-kernel-commit must be a full 40-character hexadecimal commit\n' >&2
	exit 2
fi
if [[ -z "$expected_device_tree_model" || ${#expected_device_tree_model} -gt 512 ||
	"$expected_device_tree_model" == *$'\n'* ||
	"$expected_device_tree_model" == *$'\r'* ]]; then
	printf 'error: --expected-device-tree-model must be a nonempty single-line value of at most 512 characters\n' >&2
	exit 2
fi
read_device_tree_model() {
	local model=""
	local model_with_sentinel=""
	local byte_count="0"

	if [[ -f "$device_tree_model_path" && -r "$device_tree_model_path" ]]; then
		byte_count="$(head -c 4097 -- "$device_tree_model_path" 2>/dev/null | wc -c)"
		if ((byte_count > 4096)); then
			printf 'error: live device-tree model exceeds 4096 bytes\n' >&2
			return 1
		fi
		model_with_sentinel="$(
			head -c 4096 -- "$device_tree_model_path" 2>/dev/null | tr -d '\0'
			printf '.'
		)"
		model="${model_with_sentinel%.}"
		if [[ "$model" == *$'\n'* || "$model" == *$'\r'* ]]; then
			printf 'error: live device-tree model is not a single-line value\n' >&2
			return 1
		fi
	fi
	if [[ -n "$model" ]]; then
		printf '%s\n' "$model"
	else
		printf 'unavailable\n'
	fi
}

live_device_tree_model="$(read_device_tree_model)"
if [[ "$expected_device_tree_model" != "not-provided" &&
	"$live_device_tree_model" != "$expected_device_tree_model" ]]; then
	printf 'error: live device-tree model does not match the required model\n' >&2
	printf '  required: %s\n' "$expected_device_tree_model" >&2
	printf '  live:     %s\n' "$live_device_tree_model" >&2
	exit 1
fi

hash_tool=""
if command -v sha256sum >/dev/null 2>&1; then
	hash_tool="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
	hash_tool="shasum"
else
	printf 'error: sha256sum or shasum is required to create SHA256SUMS\n' >&2
	exit 1
fi

sha256_line() {
	if [[ "$hash_tool" == "sha256sum" ]]; then
		sha256sum -- "$1"
	else
		shasum -a 256 -- "$1"
	fi
}

sha256_digest() {
	local line

	line="$(sha256_line "$1")"
	printf '%s\n' "${line%% *}"
}

source_mtime_utc() {
	local path="$1"
	local epoch

	if epoch="$(stat -c '%Y' -- "$path" 2>/dev/null)" &&
		[[ "$epoch" =~ ^[0-9]+$ ]]; then
		date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
	elif epoch="$(stat -f '%m' -- "$path" 2>/dev/null)" &&
		[[ "$epoch" =~ ^[0-9]+$ ]]; then
		date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
	else
		printf 'unavailable\n'
	fi
}

umask 077
if [[ -e "$out_dir" && ! -d "$out_dir" ]]; then
	printf 'error: output path exists and is not a directory: %s\n' "$out_dir" >&2
	exit 2
fi
if [[ -d "$out_dir" ]] && find "$out_dir" -mindepth 1 -print -quit | grep -q .; then
	printf 'error: output directory is not empty: %s\n' "$out_dir" >&2
	exit 2
fi
mkdir -p "$out_dir"
chmod 700 "$out_dir"

run_optional() {
	local output="$1"
	local output_path
	local status
	local argument
	shift

	output_path="$out_dir/$output"
	{
		printf 'Command:'
		for argument in "$@"; do
			printf ' %q' "$argument"
		done
		printf '\n'
	} >"$output_path"

	if command -v "$1" >/dev/null 2>&1; then
		printf 'Available: yes\n--- output ---\n' >>"$output_path"
		if "$@" >>"$output_path" 2>&1; then
			status=0
		else
			status=$?
		fi
		printf '\n--- end output ---\nExit status: %d\n' "$status" >>"$output_path"
	else
		printf 'Available: no\nExit status: 127\n' >>"$output_path"
	fi
}

redact_persistent_identifiers() {
	awk '
	{
		lower = tolower($0)
		if (lower ~ /(^|[^[:alnum:]_])(uuid|unique[_ -]?id|serial([_ -]?number)?)[[:space:]]*:/) {
			line = $0
			sub(/:.*/, ": <redacted>", line)
			print line
		} else {
			print
		}
	}'
}

run_optional_redacted() {
	local output="$1"
	local output_path
	local command_status
	local filter_status
	local argument
	local pipeline_status
	shift

	output_path="$out_dir/$output"
	{
		printf 'Command:'
		for argument in "$@"; do
			printf ' %q' "$argument"
		done
		printf '\nRedacted fields: UUID, unique ID, serial\n'
	} >"$output_path"

	if command -v "$1" >/dev/null 2>&1; then
		printf 'Available: yes\n--- redacted output ---\n' >>"$output_path"
		if "$@" 2>&1 | redact_persistent_identifiers >>"$output_path"; then
			pipeline_status=("${PIPESTATUS[@]}")
		else
			pipeline_status=("${PIPESTATUS[@]}")
		fi
		command_status="${pipeline_status[0]}"
		filter_status="${pipeline_status[1]}"
		printf '\n--- end output ---\nExit status: %d\nRedaction filter exit status: %d\n' \
			"$command_status" "$filter_status" >>"$output_path"
	else
		printf 'Available: no\nExit status: 127\nRedaction filter exit status: not-run\n' \
			>>"$output_path"
	fi
}

write_allowed_attr() {
	local entry="$1"
	local attribute="$2"
	local attribute_path="$entry/$attribute"
	local line
	local saw_line="false"

	[[ -f "$attribute_path" ]] || return 1
	printf '  %s:\n' "$attribute"
	if [[ ! -r "$attribute_path" ]]; then
		printf '    <unreadable>\n'
		return 0
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '    %s\n' "$line"
		saw_line="true"
	done < <(head -c 16384 -- "$attribute_path" 2>/dev/null)
	if [[ "$saw_line" == "false" ]]; then
		printf '    <empty>\n'
	fi
	return 0
}

snapshot_sysfs_entries() {
	local root="$1"
	local output="$2"
	local entry
	local entry_name
	local link_target
	local attribute
	local found_entry="false"
	local found_attribute
	shift 2
	local attributes=("$@")

	if [[ ! -d "$root" ]]; then
		printf 'sysfs path unavailable: %s\n' "$root" >"$out_dir/$output"
		return
	fi

	: >"$out_dir/$output"
	for entry in "$root"/*; do
		[[ -e "$entry" || -L "$entry" ]] || continue
		found_entry="true"
		entry_name="${entry##*/}"
		printf '[%s]\n' "$entry_name" >>"$out_dir/$output"
		if link_target="$(readlink "$entry" 2>/dev/null)"; then
			printf '  topology-link: %s\n' "$link_target" >>"$out_dir/$output"
		else
			printf '  topology-link: <not-a-symlink>\n' >>"$out_dir/$output"
		fi

		found_attribute="false"
		for attribute in "${attributes[@]}"; do
			if write_allowed_attr "$entry" "$attribute" >>"$out_dir/$output"; then
				found_attribute="true"
			fi
		done
		if [[ "$found_attribute" == "false" ]]; then
			printf '  allowed-attributes: <none present>\n' >>"$out_dir/$output"
		fi
	done

	if [[ "$found_entry" == "false" ]]; then
		printf 'no sysfs entries present under: %s\n' "$root" >"$out_dir/$output"
	fi
}

snapshot_usb4_domains() {
	local root="/sys/bus/thunderbolt/devices"
	local path
	local found="false"

	: >"$out_dir/usb4-domains.txt"
	if [[ ! -d "$root" ]]; then
		printf 'sysfs path unavailable: %s\n' "$root" >"$out_dir/usb4-domains.txt"
		return
	fi

	for path in "$root"/domain*; do
		[[ -e "$path" || -L "$path" ]] || continue
		printf '%s\n' "${path##*/}" >>"$out_dir/usb4-domains.txt"
		found="true"
	done
	if [[ "$found" == "false" ]]; then
		printf 'no USB4 domains present\n' >"$out_dir/usb4-domains.txt"
	fi
}

typec_attributes=(
	active
	accessory_mode
	data_role
	mode
	number_of_alternate_modes
	orientation
	plug_type
	port_type
	power_operation_mode
	power_role
	preferred_role
	svid
	supports_usb_power_delivery
	usb_power_delivery_revision
	usb_typec_revision
)
thunderbolt_attributes=(
	authorized
	boot
	deauthorization
	device
	device_name
	generation
	iommu_dma_protection
	link_speed
	nvm_version
	route
	rx_lanes
	rx_speed
	security
	tx_lanes
	tx_speed
	usb4_version
	vendor
	vendor_name
)
drm_attributes=(
	dpms
	enabled
	link_status
	modes
	status
)

collector_source="${BASH_SOURCE[0]}"
capture_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
boot_id="unavailable"
if [[ -r /proc/sys/kernel/random/boot_id ]]; then
	IFS= read -r boot_id </proc/sys/kernel/random/boot_id || boot_id="unavailable"
fi

{
	printf 'Capture started UTC: %s\n' "$capture_started_utc"
	printf 'Collector source modified UTC: %s\n' "$(source_mtime_utc "$collector_source")"
	printf 'Collector source SHA-256: %s\n' "$(sha256_digest "$collector_source")"
	printf 'Kernel release: %s\n' "$(uname -r)"
	printf 'Kernel build version: %s\n' "$(uname -v)"
	printf 'Expected kernel source commit: %s\n' "$expected_kernel_commit"
	printf 'Expected commit verification: metadata-only; compare with the kernel build manifest\n'
	printf 'Device tree model: %s\n' "$live_device_tree_model"
	printf 'Expected device tree model: %s\n' "$expected_device_tree_model"
	if [[ "$expected_device_tree_model" == "not-provided" ]]; then
		printf 'Device tree model verification: not requested\n'
	else
		printf 'Device tree model verification: exact match\n'
	fi
	printf 'Boot ID: %s\n' "$boot_id"
	printf 'Physical port label: %s\n' "$port_label"
	printf 'Phase: %s\n' "$phase"
	printf 'Safety boundary: explicit read-only sysfs allowlist; no raw MMIO or device-register access\n'
} >"$out_dir/metadata.txt"

snapshot_sysfs_entries \
	/sys/class/typec sys-class-typec.txt "${typec_attributes[@]}"
snapshot_sysfs_entries \
	/sys/bus/thunderbolt/devices sys-bus-thunderbolt-devices.txt \
	"${thunderbolt_attributes[@]}"
snapshot_sysfs_entries \
	/sys/class/drm sys-class-drm.txt "${drm_attributes[@]}"

run_optional lsusb-tree.txt lsusb -t
run_optional lspci-nnk.txt lspci -nnk
run_optional_redacted boltctl-list.txt boltctl list
snapshot_usb4_domains
run_optional kernel-log.txt journalctl -k -b --no-pager

capture_completed_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Capture completed UTC: %s\n' "$capture_completed_utc" >>"$out_dir/metadata.txt"

(
	cd "$out_dir"
	for output_file in *; do
		[[ "$output_file" == "SHA256SUMS" || ! -f "$output_file" ]] && continue
		sha256_line "$output_file"
	done
) >"$out_dir/SHA256SUMS"

printf 'USB4 diagnostic snapshot written to %s\n' "$out_dir"
printf 'Review and redact the directory before sharing or attaching it to an issue.\n'
