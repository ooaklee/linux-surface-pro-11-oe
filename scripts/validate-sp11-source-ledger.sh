#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ledger="${1:-${repo_dir}/config/source-ledger.tsv}"
expected_header=$'source_id\turl\tref\tcommit\tlicense\tpurpose\tstatus'

usage() {
	cat <<EOF
Usage: $(basename "$0") [LEDGER]

Validate the machine-readable Surface Pro 11 source ledger. When LEDGER is
omitted, validate config/source-ledger.tsv from this repository.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -gt 1 ]; then
	usage >&2
	exit 2
fi

if [ ! -f "$ledger" ]; then
	die "source ledger not found: $ledger"
fi

header="$(sed -n '1p' "$ledger")"
if [ "$header" != "$expected_header" ]; then
	die "line 1: expected header: $expected_header"
fi

field_errors="$(
	awk -F '\t' '
		NF != 7 {
			printf "line %d: expected 7 tab-separated fields, found %d\n", NR, NF
		}
	' "$ledger"
)"
if [ -n "$field_errors" ]; then
	printf '%s\n' "$field_errors" >&2
	exit 1
fi

line_number=1
row_count=0
seen_ids=$'\n'

while IFS=$'\t' read -r source_id url ref commit license purpose status ||
	[ -n "${source_id}${url}${ref}${commit}${license}${purpose}${status}" ]; do
	line_number=$((line_number + 1))
	row_count=$((row_count + 1))

	if [[ ! "$source_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
		die "line $line_number: invalid source_id: $source_id"
	fi
	if [[ "$seen_ids" == *$'\n'"$source_id"$'\n'* ]]; then
		die "line $line_number: duplicate source_id: $source_id"
	fi
	seen_ids+="${source_id}"$'\n'

	if [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/-]+$ ]]; then
		die "line $line_number: invalid HTTPS source URL: $url"
	fi
	if [[ ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
		die "line $line_number: invalid source ref: $ref"
	fi
	if [[ ! "$commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
		die "line $line_number: commit must be a full lowercase 40- or 64-hex object ID"
	fi
	if [[ ! "$license" =~ ^(NOASSERTION|[A-Za-z0-9.+-]+([[:space:]]+(AND|OR|WITH)[[:space:]]+[A-Za-z0-9.+-]+)*)$ ]]; then
		die "line $line_number: invalid SPDX licence expression or NOASSERTION value: $license"
	fi
	if [ -z "$purpose" ] || [[ "$purpose" =~ ^[[:space:]] ]] || [[ "$purpose" =~ [[:space:]]$ ]]; then
		die "line $line_number: purpose must be non-empty without surrounding whitespace"
	fi
	case "$status" in
		pinned|candidate|evidence-only) ;;
		*) die "line $line_number: invalid status: $status" ;;
	esac
done < <(tail -n +2 "$ledger")

if [ "$row_count" -eq 0 ]; then
	die "source ledger contains no source rows"
fi

printf 'Validated %d source-ledger rows in %s\n' "$row_count" "$ledger"
