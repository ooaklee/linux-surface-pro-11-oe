#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
validator="$repo_dir/scripts/validate-sp11-source-archive.py"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/sp11-source-archive-test.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected fixture path: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

for tool in git mktemp python3 shasum xz; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -x "$validator" ] || die "missing executable source archive validator"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-source-archive-test.XXXXXX")"
kernel_repo="$temporary_root/kernel"
touch_repo="$temporary_root/touchscreen"
mkdir -p "$kernel_repo/source" "$touch_repo/phase55/modules"

git -C "$kernel_repo" init --quiet --initial-branch=fixture
git -C "$kernel_repo" config user.name 'SP11 source fixture'
git -C "$kernel_repo" config user.email 'sp11-source@example.invalid'
printf '%s\n' 'payload filter=hostile' > "$kernel_repo/.gitattributes"
printf 'raw payload\r\n' > "$kernel_repo/payload"
printf 'fixture source\n' > "$kernel_repo/source/file.c"
ln -s ../payload "$kernel_repo/source/payload-link"
git -C "$kernel_repo" add .
git -C "$kernel_repo" commit --quiet -m 'Create exact-tree fixture'
kernel_tree="$(git -C "$kernel_repo" rev-parse 'HEAD^{tree}')"
kernel_archive="$temporary_root/fixture-patched-source.tar.xz"
git -C "$kernel_repo" archive --format=tar --prefix=kernel-source/ "$kernel_tree" |
  xz --threads=1 -6 > "$kernel_archive"

hostile_home="$temporary_root/hostile-home"
mkdir -p "$hostile_home"
cat > "$hostile_home/.gitconfig" <<'EOF_GITCONFIG'
[filter "hostile"]
  clean = false
  required = true
EOF_GITCONFIG
HOME="$hostile_home" GIT_CONFIG_GLOBAL="$hostile_home/.gitconfig" \
  "$validator" kernel --archive "$kernel_archive" --expected-tree "$kernel_tree" \
  > "$temporary_root/kernel-valid.log"
grep -Fq "Kernel tree ID: $kernel_tree" "$temporary_root/kernel-valid.log" ||
  die "valid raw kernel tree identity was not reported"

sha256_repo="$temporary_root/kernel-sha256"
if git -C "$temporary_root" init --quiet --initial-branch=fixture \
    --object-format=sha256 "$sha256_repo" >/dev/null 2>&1; then
  git -C "$sha256_repo" config user.name 'SP11 SHA-256 fixture'
  git -C "$sha256_repo" config user.email 'sp11-sha256@example.invalid'
  mkdir -p "$sha256_repo/source"
  printf 'SHA-256 tree fixture\n' > "$sha256_repo/source/file.c"
  printf '#!/bin/sh\nexit 0\n' > "$sha256_repo/source/tool"
  chmod +x "$sha256_repo/source/tool"
  git -C "$sha256_repo" add .
  git -C "$sha256_repo" commit --quiet -m 'Create SHA-256 archive fixture'
  sha256_tree="$(git -C "$sha256_repo" rev-parse 'HEAD^{tree}')"
  [ "${#sha256_tree}" -eq 64 ] || die "SHA-256 Git fixture did not produce a 64-hex tree"
  sha256_archive="$temporary_root/sha256-patched-source.tar.xz"
  git -C "$sha256_repo" archive --format=tar --prefix=sha256-source/ "$sha256_tree" |
    xz --threads=1 -6 > "$sha256_archive"
  "$validator" kernel --archive "$sha256_archive" --expected-tree "$sha256_tree" \
    > "$temporary_root/sha256-valid.log"
  grep -Fq "Kernel tree ID: $sha256_tree" "$temporary_root/sha256-valid.log" ||
    die "SHA-256 Git archive tree reconstruction failed"
else
  printf 'Skipping SHA-256 Git archive fixture: installed Git lacks SHA-256 repositories.\n'
fi

upper_blob="$(printf 'upper-case Git path\n' | git -C "$kernel_repo" hash-object -w --stdin)"
lower_blob="$(printf 'lower-case Git path\n' | git -C "$kernel_repo" hash-object -w --stdin)"
case_tree="$(printf '100644 blob %s\txt_CONNMARK.h\n100644 blob %s\txt_connmark.h\n' \
  "$upper_blob" "$lower_blob" | git -C "$kernel_repo" mktree)"
case_archive="$temporary_root/case-collision-patched-source.tar.xz"
git -C "$kernel_repo" archive --format=tar --prefix=case-source/ "$case_tree" |
  xz --threads=1 -6 > "$case_archive"
"$validator" kernel --archive "$case_archive" --expected-tree "$case_tree" \
  > "$temporary_root/case-collision-valid.log"
grep -Fq "Kernel tree ID: $case_tree" "$temporary_root/case-collision-valid.log" ||
  die "case-distinct Git paths were collapsed by host filesystem semantics"

deep_blob="$(printf 'deep Git path\n' | git -C "$kernel_repo" hash-object -w --stdin)"
deep_tree="$(printf '100644 blob %s\tleaf\n' "$deep_blob" | git -C "$kernel_repo" mktree)"
for ((depth = 0; depth < 1100; depth++)); do
  deep_tree="$(printf '040000 tree %s\td\n' "$deep_tree" | git -C "$kernel_repo" mktree)"
done
deep_archive="$temporary_root/deep-path-patched-source.tar.xz"
git -C "$kernel_repo" archive --format=tar --prefix=deep-source/ "$deep_tree" |
  xz --threads=1 -6 > "$deep_archive"
"$validator" kernel --archive "$deep_archive" --expected-tree "$deep_tree" \
  > "$temporary_root/deep-path-valid.log"
grep -Fq "Kernel tree ID: $deep_tree" "$temporary_root/deep-path-valid.log" ||
  die "deep valid Git tree exceeded Python recursion semantics"

for invalid_id in "+$kernel_tree" " $kernel_tree" "$kernel_tree "; do
  if "$validator" kernel --archive "$kernel_archive" --expected-tree "$invalid_id" \
      > "$temporary_root/invalid-id.log" 2>&1; then
    die "validator accepted a signed or whitespace-padded Git object ID"
  fi
  grep -Fq 'exactly 40 or 64 hexadecimal' "$temporary_root/invalid-id.log" ||
    die "invalid object ID failure was not explicit"
done

git -C "$touch_repo" init --quiet --initial-branch=fixture
git -C "$touch_repo" config user.name 'SP11 source fixture'
git -C "$touch_repo" config user.email 'sp11-source@example.invalid'
printf 'fixture licence\n' > "$touch_repo/LICENSE"
printf 'obj-m += fixture.o\n' > "$touch_repo/phase55/modules/Makefile"
printf 'int fixture(void) { return 0; }\n' > "$touch_repo/phase55/modules/fixture.c"
printf 'not corresponding source\n' > "$touch_repo/README.md"
git -C "$touch_repo" add .
git -C "$touch_repo" commit --quiet -m 'Create touchscreen subset fixture'
touch_commit="$(git -C "$touch_repo" rev-parse 'HEAD^{commit}')"
touch_tree="$(git -C "$touch_repo" rev-parse "$touch_commit:phase55/modules")"
touch_license="$(git -C "$touch_repo" rev-parse "$touch_commit:LICENSE")"
touch_archive="$temporary_root/sp11-touchscreen-modules-source-$touch_commit.tar.xz"
git -C "$touch_repo" archive \
  --format=tar \
  --prefix="touchscreen-source-$touch_commit/" \
  "$touch_commit" \
  LICENSE phase55/modules |
  xz --threads=1 -6 > "$touch_archive"
"$validator" touchscreen \
  --archive "$touch_archive" \
  --expected-modules-tree "$touch_tree" \
  --expected-license-blob "$touch_license" \
  --license-mode 100644 \
  --expected-archive-comment "$touch_commit" \
  > "$temporary_root/touch-valid.log"
grep -Fq "Touchscreen modules tree ID: $touch_tree" "$temporary_root/touch-valid.log" ||
  die "valid touchscreen subtree identity was not reported"
mixed_comment="$(printf '0%.0s' {1..64})"
if "$validator" touchscreen \
    --archive "$touch_archive" \
    --expected-modules-tree "$touch_tree" \
    --expected-license-blob "$touch_license" \
    --license-mode 100644 \
    --expected-archive-comment "$mixed_comment" \
    > "$temporary_root/touch-mixed-format.log" 2>&1; then
  die "validator accepted mixed touchscreen commit/object formats"
fi
grep -Fq 'mixed Git object formats' "$temporary_root/touch-mixed-format.log" ||
  die "mixed touchscreen object-format rejection was not explicit"

printf 'plain text is not source\n' > "$temporary_root/plain-patched-source.tar.xz"
head -c 64 "$kernel_archive" > "$temporary_root/truncated-patched-source.tar.xz"

python3 - "$temporary_root" <<'PY_FIXTURES'
import io
import lzma
import pathlib
import sys
import tarfile
import zlib

root = pathlib.Path(sys.argv[1])

def archive(name, entries, pax=None, canonical_owner=True):
    with tarfile.open(root / name, "w:xz", format=tarfile.PAX_FORMAT, pax_headers=pax or {}) as output:
        for kind, path, value in entries:
            info = tarfile.TarInfo(path)
            info.mtime = 0
            info.uid = 0 if canonical_owner else 501
            info.gid = 0 if canonical_owner else 20
            info.uname = "root" if canonical_owner else "private-user"
            info.gname = "root" if canonical_owner else "private-group"
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o775
                output.addfile(info)
            elif kind == "file":
                data = value.encode()
                info.type = tarfile.REGTYPE
                info.mode = 0o664
                info.size = len(data)
                output.addfile(info, io.BytesIO(data))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.mode = 0o777
                info.linkname = value
                output.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.mode = 0o664
                info.linkname = value
                output.addfile(info)

archive("traversal-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("file", "source/../../escaped", "escape"),
])
archive("multi-root-patched-source.tar.xz", [
    ("dir", "one", ""), ("file", "one/a", "a"),
    ("dir", "two", ""), ("file", "two/b", "b"),
])
archive("symlink-escape-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("symlink", "source/link", "../../outside"),
])
archive("symlink-parent-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("symlink", "source/link", "target"),
    ("file", "source/link/child", "unsafe"),
])
archive("dot-git-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("dir", "source/.git", ""),
    ("file", "source/.git/config", "unsafe"),
])
archive("hardlink-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("file", "source/file", "data"),
    ("hardlink", "source/hard", "source/file"),
])
archive("untrusted-pax-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("file", "source/file", "data"),
], {"path": "forged"})
archive("owner-metadata-patched-source.tar.xz", [
    ("dir", "source", ""),
    ("file", "source/file", "data"),
], canonical_owner=False)
archive("control-root-patched-source.tar.xz", [
    ("dir", "source\nforged", ""),
    ("file", "source\nforged/file", "data"),
])

kernel_archive = root / "fixture-patched-source.tar.xz"
over_limit = bytearray(kernel_archive.read_bytes())
block_start = 12
block_header_size = (over_limit[block_start] + 1) * 4
block_header = bytearray(over_limit[block_start:block_start + block_header_size])

def read_vli(data, offset):
    value = 0
    shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        if byte & 0x80 == 0:
            return value, offset
        shift += 7

flags = block_header[1]
offset = 2
if flags & 0x40:
    _, offset = read_vli(block_header, offset)
if flags & 0x80:
    _, offset = read_vli(block_header, offset)
filter_id, offset = read_vli(block_header, offset)
property_size, offset = read_vli(block_header, offset)
assert flags & 0x03 == 0 and filter_id == 0x21 and property_size == 1
block_header[offset] = 40
block_header[-4:] = zlib.crc32(block_header[:-4]).to_bytes(4, "little")
over_limit[block_start:block_start + block_header_size] = block_header
(root / "over-limit-dictionary-patched-source.tar.xz").write_bytes(over_limit)

with lzma.open(kernel_archive, "rb") as source:
    raw_tar = source.read()
with lzma.open(root / "nonzero-tail-patched-source.tar.xz", "wb") as output:
    output.write(raw_tar + b"hidden")
second_buffer = io.BytesIO()
with tarfile.open(fileobj=second_buffer, mode="w") as second:
    info = tarfile.TarInfo("second-root")
    info.type = tarfile.DIRTYPE
    info.mode = 0o775
    second.addfile(info)
    data = b"second archive"
    info = tarfile.TarInfo("second-root/file")
    info.type = tarfile.REGTYPE
    info.mode = 0o664
    info.size = len(data)
    second.addfile(info, io.BytesIO(data))
with lzma.open(root / "concatenated-tar-patched-source.tar.xz", "wb") as output:
    output.write(raw_tar + second_buffer.getvalue())
PY_FIXTURES

cp "$kernel_archive" "$temporary_root/appended-xz-patched-source.tar.xz"
printf 'hidden after xz\n' >> "$temporary_root/appended-xz-patched-source.tar.xz"

expect_kernel_failure() {
  local archive="$1" expected="$2" log
  log="$temporary_root/$(basename "$archive").log"
  if "$validator" kernel --archive "$archive" --expected-tree "$kernel_tree" >"$log" 2>&1; then
    die "validator accepted unsafe archive $(basename "$archive")"
  fi
  grep -Fqi "$expected" "$log" || die "unsafe archive failure did not mention $expected"
}

expect_kernel_failure "$temporary_root/plain-patched-source.tar.xz" XZ-compressed
expect_kernel_failure "$temporary_root/truncated-patched-source.tar.xz" truncated
expect_kernel_failure "$temporary_root/over-limit-dictionary-patched-source.tar.xz" 'memory limit'
expect_kernel_failure "$temporary_root/traversal-patched-source.tar.xz" path
expect_kernel_failure "$temporary_root/multi-root-patched-source.tar.xz" top-level
expect_kernel_failure "$temporary_root/symlink-escape-patched-source.tar.xz" escapes
expect_kernel_failure "$temporary_root/symlink-parent-patched-source.tar.xz" symlink
expect_kernel_failure "$temporary_root/dot-git-patched-source.tar.xz" .git
expect_kernel_failure "$temporary_root/hardlink-patched-source.tar.xz" non-file
expect_kernel_failure "$temporary_root/untrusted-pax-patched-source.tar.xz" pax
expect_kernel_failure "$temporary_root/owner-metadata-patched-source.tar.xz" owner
expect_kernel_failure "$temporary_root/control-root-patched-source.tar.xz" path
expect_kernel_failure "$temporary_root/appended-xz-patched-source.tar.xz" 'after its single XZ stream'
expect_kernel_failure "$temporary_root/nonzero-tail-patched-source.tar.xz" non-zero
expect_kernel_failure "$temporary_root/concatenated-tar-patched-source.tar.xz" concatenated
[ ! -e "$temporary_root/escaped" ] || die "path-traversal fixture wrote outside extraction root"

wrong_tree="$(printf '0%.0s' {1..40})"
if "$validator" kernel --archive "$kernel_archive" --expected-tree "$wrong_tree" \
    > "$temporary_root/wrong-tree.log" 2>&1; then
  die "validator accepted a kernel archive for the wrong Git tree"
fi
grep -Fq 'does not match' "$temporary_root/wrong-tree.log" ||
  die "wrong-tree failure was not explicit"

touch_extra="$temporary_root/sp11-touchscreen-modules-source-extra.tar.xz"
git -C "$touch_repo" archive \
  --format=tar \
  --prefix="touchscreen-source-$touch_commit/" \
  "$touch_commit" \
  LICENSE README.md phase55/modules |
  xz --threads=1 -6 > "$touch_extra"
if "$validator" touchscreen \
    --archive "$touch_extra" \
    --expected-modules-tree "$touch_tree" \
    --expected-license-blob "$touch_license" \
    --license-mode 100644 \
    --expected-archive-comment "$touch_commit" \
    > "$temporary_root/touch-extra.log" 2>&1; then
  die "validator accepted an out-of-contract touchscreen source path"
fi
grep -Fq 'out-of-contract path' "$temporary_root/touch-extra.log" ||
  die "touchscreen extra-path failure was not explicit"

printf 'Source archive identity and extraction fixtures passed.\n'
