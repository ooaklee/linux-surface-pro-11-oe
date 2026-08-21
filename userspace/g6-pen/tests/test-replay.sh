#!/bin/sh
set -eu

binary=${1:-./g6-pen}
base_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
actual=$(mktemp "${TMPDIR:-/tmp}/g6-pen-replay.XXXXXX")
binary_corpus=$(mktemp "${TMPDIR:-/tmp}/g6-pen-replay.XXXXXX")
invalid_corpus=$(mktemp "${TMPDIR:-/tmp}/g6-pen-replay.XXXXXX")
zero_corpus=$(mktemp "${TMPDIR:-/tmp}/g6-pen-replay.XXXXXX")
zero_expected=$(mktemp "${TMPDIR:-/tmp}/g6-pen-replay.XXXXXX")
trap 'rm -f "$actual" "$binary_corpus" "$invalid_corpus" "$zero_corpus" "$zero_expected"' EXIT HUP INT TERM

"$binary" \
	--config "$base_dir/tests/corpus/synthetic-hover.conf" \
	--replay-text "$base_dir/tests/corpus/synthetic-hover.g6t" \
	--emit-json >"$actual"
diff -u "$base_dir/tests/corpus/synthetic-hover.expected.jsonl" "$actual"

python3 "$base_dir/tools/g6-corpus.py" pack \
	"$base_dir/tests/corpus/synthetic-hover.g6t" "$binary_corpus"
"$binary" \
	--config "$base_dir/tests/corpus/synthetic-hover.conf" \
	--replay "$binary_corpus" \
	--emit-json >"$actual"
diff -u "$base_dir/tests/corpus/synthetic-hover.expected.jsonl" "$actual"

printf 'G6T1\n1 1 1 0x0c 0 -1\n' >"$invalid_corpus"
if "$binary" --config "$base_dir/tests/corpus/synthetic-hover.conf" \
	--replay-text "$invalid_corpus" >/dev/null 2>&1; then
	echo "g6-pen replay test: signed hex byte was accepted" >&2
	exit 1
fi
printf 'G6T1\n1 -1 1 0x0c 0 00\n' >"$invalid_corpus"
if "$binary" --config "$base_dir/tests/corpus/synthetic-hover.conf" \
	--replay-text "$invalid_corpus" >/dev/null 2>&1; then
	echo "g6-pen replay test: signed timestamp was accepted" >&2
	exit 1
fi

cat >"$zero_corpus" <<'EOF'
G6T1
1 0 1 0x0c 0 00
1 0 2 0x0b 0 0000000000000000
1 0 3 0x1a 0 00
1 0 4 0x0d 0 00
1 0 5 0x0b 0 6400000000000000
EOF
cat >"$zero_expected" <<'EOF'
{"timestamp_ns":0,"generation":1,"valid":99,"proximity":true,"tool":"pen","tip":false,"barrel":false,"secondary":false,"x":0,"y":0,"pressure":0,"tilt_x":0,"tilt_y":0,"quality":1000}
{"timestamp_ns":0,"generation":1,"valid":33,"proximity":false,"tool":"pen","tip":false,"barrel":false,"secondary":false,"x":0,"y":0,"pressure":0,"tilt_x":0,"tilt_y":0,"quality":0}
EOF
"$binary" --config "$base_dir/tests/corpus/synthetic-hover.conf" \
	--replay-text "$zero_corpus" --emit-json >"$actual"
diff -u "$zero_expected" "$actual"
echo "g6-pen replay test: PASS"
