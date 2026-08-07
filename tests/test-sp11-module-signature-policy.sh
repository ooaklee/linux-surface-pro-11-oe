#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scanner="$repo_dir/scripts/validate-sp11-module-signatures.py"
temporary_parent=""
temporary_root=""

cleanup() {
	[ -n "$temporary_root" ] || return 0
	case "$temporary_root" in
		"$temporary_parent"/sp11-module-signatures.*)
			chmod -R u+w "$temporary_root" 2>/dev/null || true
			rm -rf -- "$temporary_root"
			;;
		*)
			printf 'warning: refusing to remove unexpected temporary path\n' >&2
			;;
	esac
}
trap cleanup EXIT

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

for tool in chmod cmp grep mktemp python3 zstd; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -f "$scanner" ] || die "module-signature scanner is missing"

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-module-signatures.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
fixtures="$temporary_root/fixtures"
results="$temporary_root/results"
mkdir -p "$fixtures" "$results"

python3 - "$fixtures" <<'PY'
from __future__ import annotations

import gzip
import io
import lzma
import subprocess
import sys
import tarfile
from pathlib import Path


root = Path(sys.argv[1])
abi = "7.2-rc5-jg-0sp11fixture1-qcom-x1e"
version = "7.2-rc5-jg-0sp11fixture1"
marker = b"~Module signature appended~\n"


def module_bytes(compression: str, signed: bool, after_marker: bool = False) -> bytes:
    payload = b"\x7fELFsynthetic-sp11-module-" + compression.encode("ascii")
    if signed or after_marker:
        payload += marker
    if after_marker:
        payload += b"not-at-eof"
    if compression == "none":
        return payload
    if compression == "gzip":
        return gzip.compress(payload, mtime=0)
    if compression == "xz":
        return lzma.compress(payload, format=lzma.FORMAT_XZ)
    if compression == "zstd":
        return subprocess.run(
            ["zstd", "--compress", "--stdout", "--quiet"],
            input=payload,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
    raise ValueError(compression)


def regular(name: str, data: bytes) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.mode = 0o644
    info.uid = 0
    info.gid = 0
    info.size = len(data)
    return info


def tar_bytes(
    entries: list[tuple[str, str, bytes | str]],
    archive_format: int = tarfile.GNU_FORMAT,
) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=archive_format) as archive:
        for kind, name, value in entries:
            if kind == "file":
                assert isinstance(value, bytes)
                archive.addfile(regular(name, value), io.BytesIO(value))
            elif kind == "symlink":
                assert isinstance(value, str)
                info = tarfile.TarInfo(name)
                info.type = tarfile.SYMTYPE
                info.linkname = value
                info.mode = 0o777
                archive.addfile(info)
            elif kind == "hardlink":
                assert isinstance(value, str)
                info = tarfile.TarInfo(name)
                info.type = tarfile.LNKTYPE
                info.linkname = value
                info.mode = 0o644
                archive.addfile(info)
            elif kind in ("nonzero-directory", "nonzero-symlink", "nonzero-hardlink"):
                info = tarfile.TarInfo(name)
                info.size = 512
                if kind == "nonzero-directory":
                    info.type = tarfile.DIRTYPE
                else:
                    assert isinstance(value, str)
                    info.type = (
                        tarfile.SYMTYPE if kind == "nonzero-symlink" else tarfile.LNKTYPE
                    )
                    info.linkname = value
                archive.addfile(info)
            elif kind == "pax-size-override":
                assert isinstance(value, bytes)
                info = regular(name, value)
                info.pax_headers = {"size": "0"}
                archive.addfile(info, io.BytesIO(value))
            elif kind == "sparse":
                info = tarfile.TarInfo(name)
                info.type = tarfile.GNUTYPE_SPARSE
                archive.addfile(info)
            elif kind == "unsupported":
                info = tarfile.TarInfo(name)
                info.type = b"V"
                archive.addfile(info)
            elif kind == "fifo":
                info = tarfile.TarInfo(name)
                info.type = tarfile.FIFOTYPE
                archive.addfile(info)
            else:
                raise ValueError(kind)
    return output.getvalue()


def ar_header(name: str, size: int) -> bytes:
    encoded_name = (name + "/").encode("ascii")
    header = b"".join(
        (
            encoded_name.ljust(16, b" "),
            b"0".ljust(12, b" "),
            b"0".ljust(6, b" "),
            b"0".ljust(6, b" "),
            b"100644".ljust(8, b" "),
            str(size).encode("ascii").ljust(10, b" "),
            b"`\n",
        )
    )
    assert len(header) == 60
    return header


def ar_member(name: str, data: bytes) -> bytes:
    header = ar_header(name, len(data))
    return header + data + (b"\n" if len(data) % 2 else b"")


def raw_tar_record(name: str, member_type: bytes, payload: bytes) -> bytes:
    info = tarfile.TarInfo(name)
    info.type = member_type
    info.size = len(payload)
    header = info.tobuf(format=tarfile.GNU_FORMAT)
    padding = b"\x00" * ((512 - len(payload) % 512) % 512)
    return header + payload + padding


def package(
    directory: str,
    package_name: str,
    entries: list[tuple[str, str, bytes | str]],
    *,
    extra_ar: list[tuple[str, bytes]] | None = None,
    data_compression: str = "none",
    data_trailing: bytes = b"",
    tar_format: int = tarfile.GNU_FORMAT,
    data_tar_override: bytes | None = None,
) -> Path:
    target_dir = root / directory
    target_dir.mkdir(parents=True, exist_ok=True)
    control = (
        f"Package: {package_name}\n"
        f"Version: {version}\n"
        "Architecture: arm64\n"
        "Description: synthetic module signature fixture\n"
    ).encode("utf-8")
    control_tar = tar_bytes([("file", "control", control)])
    data_tar = (
        data_tar_override
        if data_tar_override is not None
        else tar_bytes(entries, tar_format)
    )
    if data_compression == "xz":
        data_member_name = "data.tar.xz"
        data_tar = lzma.compress(data_tar, format=lzma.FORMAT_XZ) + data_trailing
    elif data_compression == "none":
        data_member_name = "data.tar"
        data_tar += data_trailing
    else:
        raise ValueError(data_compression)
    members = [
        ("debian-binary", b"2.0\n"),
        ("control.tar", control_tar),
        (data_member_name, data_tar),
    ]
    if extra_ar:
        members.extend(extra_ar)
    data = b"!<arch>\n" + b"".join(ar_member(name, value) for name, value in members)
    target = target_dir / f"{package_name}_{version}_arm64.deb"
    target.write_bytes(data)
    return target


def module_entries(signed: bool) -> list[tuple[str, str, bytes | str]]:
    entries: list[tuple[str, str, bytes | str]] = []
    suffixes = {"none": ".ko", "gzip": ".ko.gz", "xz": ".ko.xz", "zstd": ".ko.zst"}
    for compression, suffix in suffixes.items():
        entries.append(
            (
                "file",
                f"usr/lib/modules/{abi}/kernel/fixture/{compression}{suffix}",
                module_bytes(compression, signed),
            )
        )
    entries.extend(
        (
            ("file", "boot/config-fixture", b"CONFIG_FIXTURE=y\n"),
            ("file", f"usr/lib/modules/{abi}/vdso/vdso.so", b"\x7fELFvdso"),
            (
                "symlink",
                f"usr/lib/modules/{abi}/vdso/.build-id/aa/fixture.debug",
                "../../vdso.so",
            ),
            (
                "hardlink",
                f"usr/lib/modules/{abi}/vdso/.build-id/bb/fixture.debug",
                f"usr/lib/modules/{abi}/vdso/vdso.so",
            ),
        )
    )
    return entries


modules_name = f"linux-modules-{abi}"
extra_name = f"linux-modules-extra-{abi}"
package("unsigned", modules_name, module_entries(False))
package("signed", modules_name, module_entries(True))
package(
    "marker-not-eof",
    modules_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/not-at-eof.ko",
            module_bytes("none", False, after_marker=True),
        )
    ],
)
package(
    "extra",
    extra_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/extra.ko",
            module_bytes("none", False),
        )
    ],
)
package(
    "duplicate-path",
    modules_name,
    [
        ("file", f"usr/lib/modules/{abi}/kernel/fixture/repeated.ko", module_bytes("none", False)),
        ("file", f"usr/lib/modules/{abi}/kernel/fixture/repeated.ko", module_bytes("none", False)),
    ],
)
package(
    "traversal",
    modules_name,
    [("file", f"usr/lib/modules/{abi}/kernel/../../escape.ko", module_bytes("none", False))],
)
package(
    "extra-path",
    modules_name,
    [("file", f"usr/lib/modules/{abi}/updates/escape.ko", module_bytes("none", False))],
)
package(
    "special",
    modules_name,
    [
        ("file", f"usr/lib/modules/{abi}/kernel/fixture/good.ko", module_bytes("none", False)),
        ("fifo", "usr/lib/fixture-fifo", b""),
    ],
)
package(
    "escaping-link",
    modules_name,
    [
        ("file", f"usr/lib/modules/{abi}/kernel/fixture/good.ko", module_bytes("none", False)),
        ("symlink", "usr/lib/fixture-link", "../../../outside"),
    ],
)
package(
    "module-link",
    modules_name,
    [
        ("file", f"usr/lib/modules/{abi}/kernel/fixture/good.ko", module_bytes("none", False)),
        ("symlink", f"usr/lib/modules/{abi}/kernel/fixture/hidden.ko", "good.ko"),
    ],
)
package(
    "malformed-compression",
    modules_name,
    [("file", f"usr/lib/modules/{abi}/kernel/fixture/bad.ko.gz", b"not-gzip")],
)
package(
    "trailing-xz-module",
    modules_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/trailing.ko.xz",
            module_bytes("xz", False) + b"trailing-garbage",
        )
    ],
)
package(
    "trailing-xz-data",
    modules_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        )
    ],
    data_compression="xz",
    data_trailing=b"trailing-garbage",
)
long_component = "a" * 9000
package(
    "huge-gnu-name",
    modules_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/{long_component}.ko",
            module_bytes("none", False),
        )
    ],
)
package(
    "huge-pax-name",
    modules_name,
    [
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/{long_component}.ko",
            module_bytes("none", False),
        )
    ],
    tar_format=tarfile.PAX_FORMAT,
)
package(
    "nonzero-directory-bypass",
    modules_name,
    [
        ("nonzero-directory", "usr/lib/nonzero-directory", b""),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/{long_component}.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "nonzero-symlink-bypass",
    modules_name,
    [
        ("nonzero-symlink", "usr/lib/nonzero-symlink", "target"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/{long_component}.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "nonzero-hardlink-bypass",
    modules_name,
    [
        ("nonzero-hardlink", "usr/lib/nonzero-hardlink", "usr/lib/target"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/{long_component}.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "pax-size-override",
    modules_name,
    [
        (
            "pax-size-override",
            f"usr/lib/modules/{abi}/kernel/fixture/pax-size.ko",
            module_bytes("none", False),
        )
    ],
    tar_format=tarfile.PAX_FORMAT,
)
package(
    "sparse",
    modules_name,
    [
        ("sparse", "usr/lib/sparse-entry", b""),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "unsupported-type",
    modules_name,
    [
        ("unsupported", "unsupported-volume", b""),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
nested_module = module_bytes("none", False)
nested_gnu_record = raw_tar_record(
    "././@LongLink", tarfile.GNUTYPE_LONGNAME, b"nested-name\x00"
)
nested_gnu_tar = (
    nested_gnu_record * 1500
    + raw_tar_record(
        f"usr/lib/modules/{abi}/kernel/fixture/nested.ko",
        tarfile.REGTYPE,
        nested_module,
    )
    + b"\x00" * 1024
)
package(
    "nested-gnu-metadata",
    modules_name,
    [],
    data_tar_override=nested_gnu_tar,
)
package(
    "kernel-root-symlink",
    modules_name,
    [
        ("file", "usr/lib/kernel-target", b"target"),
        ("symlink", f"usr/lib/modules/{abi}/kernel", "../../../kernel-target"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "kernel-root-hardlink",
    modules_name,
    [
        ("file", "usr/lib/kernel-target", b"target"),
        ("hardlink", f"usr/lib/modules/{abi}/kernel", "usr/lib/kernel-target"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "regular-ancestor",
    modules_name,
    [
        ("file", f"usr/lib/modules/{abi}/kernel/fixture", b"not-a-directory"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "link-ancestor",
    modules_name,
    [
        ("file", "usr/lib/metadata-target", b"target"),
        ("symlink", "usr/lib/metadata-parent", "metadata-target"),
        ("file", "usr/lib/metadata-parent/child", b"child"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "dangling-link",
    modules_name,
    [
        ("symlink", "usr/lib/dangling", "missing"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "chained-link",
    modules_name,
    [
        ("file", "usr/lib/target", b"target"),
        ("symlink", "usr/lib/link-a", "target"),
        ("symlink", "usr/lib/link-b", "link-a"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
package(
    "dangling-hardlink",
    modules_name,
    [
        ("hardlink", "usr/lib/dangling-hardlink", "usr/lib/missing"),
        (
            "file",
            f"usr/lib/modules/{abi}/kernel/fixture/good.ko",
            module_bytes("none", False),
        ),
    ],
)
valid = package("duplicate-ar", modules_name, module_entries(False))
duplicate_ar_data = valid.read_bytes()
data_header = ar_member("data.tar", b"duplicate")
valid.write_bytes(duplicate_ar_data + data_header)
package("unexpected-ar", modules_name, module_entries(False), extra_ar=[("unexpected", b"x")])
package("wrong-role", f"linux-image-{abi}", module_entries(False))

invalid_dir = root / "malformed"
invalid_dir.mkdir()
expected_name = f"{modules_name}_{version}_arm64.deb"
(invalid_dir / expected_name).write_bytes(b"not-a-deb")
valid_bytes = (root / "unsigned" / expected_name).read_bytes()
truncated_dir = root / "truncated"
truncated_dir.mkdir()
(truncated_dir / expected_name).write_bytes(valid_bytes[:-1])
huge_ar_dir = root / "huge-ar"
huge_ar_dir.mkdir()
(huge_ar_dir / expected_name).write_bytes(
    b"!<arch>\n" + ar_header("debian-binary", 3_999_999_999)
)
PY

package_name="linux-modules-7.2-rc5-jg-0sp11fixture1-qcom-x1e_7.2-rc5-jg-0sp11fixture1_arm64.deb"
extra_name="linux-modules-extra-7.2-rc5-jg-0sp11fixture1-qcom-x1e_7.2-rc5-jg-0sp11fixture1_arm64.deb"
unsigned_deb="$fixtures/unsigned/$package_name"
signed_deb="$fixtures/signed/$package_name"
not_at_eof_deb="$fixtures/marker-not-eof/$package_name"
extra_deb="$fixtures/extra/$extra_name"

expect_failure() {
	label="$1"
	expected="$2"
	shift 2
	stdout_file="$results/$label.stdout"
	stderr_file="$results/$label.stderr"
	if "$scanner" "$@" > "$stdout_file" 2> "$stderr_file"; then
		die "$label fixture was accepted"
	fi
	[ ! -s "$stdout_file" ] || die "$label failure emitted a partial report"
	grep -Fq "$expected" "$stderr_file" || {
		cat "$stderr_file" >&2
		die "$label rejection was not explicit"
	}
	if grep -Fq "$temporary_root" "$stderr_file"; then
		die "$label rejection leaked a local path"
	fi
}

chmod 0444 "$unsigned_deb" "$signed_deb" "$not_at_eof_deb" "$extra_deb"
chmod 0555 "$fixtures/unsigned" "$fixtures/signed" "$fixtures/marker-not-eof" "$fixtures/extra"
before_hash="$(python3 - "$unsigned_deb" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"

"$scanner" --expect unsigned "$unsigned_deb" > "$results/unsigned.report"
grep -Fxq 'Package count: 1' "$results/unsigned.report"
grep -Fxq 'Module count: 4' "$results/unsigned.report"
grep -Fxq 'Signed module count: 0' "$results/unsigned.report"
grep -Fxq 'Unsigned module count: 4' "$results/unsigned.report"
grep -Fxq 'Uncompressed module count: 1' "$results/unsigned.report"
grep -Fxq 'Gzip module count: 1' "$results/unsigned.report"
grep -Fxq 'XZ module count: 1' "$results/unsigned.report"
grep -Fxq 'Zstandard module count: 1' "$results/unsigned.report"
grep -Fxq 'Expected signature state: unsigned' "$results/unsigned.report"
grep -Fxq 'Scan completed: true' "$results/unsigned.report"

after_hash="$(python3 - "$unsigned_deb" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
[ "$before_hash" = "$after_hash" ] || die "scanner modified its read-only input"
if grep -Fq "$temporary_root" "$results/unsigned.report"; then
	die "successful report leaked a local path"
fi

"$scanner" --expect any "$signed_deb" > "$results/signed.report"
grep -Fxq 'Module count: 4' "$results/signed.report"
grep -Fxq 'Signed module count: 4' "$results/signed.report"
grep -Fxq 'Unsigned module count: 0' "$results/signed.report"
expect_failure signed-as-unsigned 'unsigned expectation failed (signed=4, unsigned=0)' \
	--expect unsigned "$signed_deb"
expect_failure unsigned-as-signed 'signed expectation failed (signed=0, unsigned=4)' \
	--expect signed "$unsigned_deb"

"$scanner" --expect unsigned "$not_at_eof_deb" > "$results/not-at-eof.report"
grep -Fxq 'Signed module count: 0' "$results/not-at-eof.report"
grep -Fxq 'Unsigned module count: 1' "$results/not-at-eof.report"

"$scanner" --expect unsigned "$extra_deb" "$unsigned_deb" > "$results/combined-a.report"
"$scanner" --expect unsigned "$unsigned_deb" "$extra_deb" > "$results/combined-b.report"
cmp "$results/combined-a.report" "$results/combined-b.report"
grep -Fxq 'Package count: 2' "$results/combined-a.report"
grep -Fxq 'Package 1 role: modules' "$results/combined-a.report"
grep -Fxq 'Package 2 role: modules-extra' "$results/combined-a.report"
grep -Fxq 'Module count: 5' "$results/combined-a.report"
grep -Fxq 'Signed module count: 0' "$results/combined-a.report"
grep -Fxq 'Unsigned module count: 5' "$results/combined-a.report"

expect_failure malformed-deb 'input is not a Debian ar archive' \
	"$fixtures/malformed/$package_name"
expect_failure truncated-deb 'package contains a truncated ar member' \
	"$fixtures/truncated/$package_name"
expect_failure duplicate-path 'data archive contains a duplicate member path' \
	"$fixtures/duplicate-path/$package_name"
expect_failure traversal 'package archive contains a non-canonical member path' \
	"$fixtures/traversal/$package_name"
expect_failure extra-path 'module-like file is outside the expected ABI kernel tree' \
	"$fixtures/extra-path/$package_name"
expect_failure special 'tar archive contains an unsupported raw member type' \
	"$fixtures/special/$package_name"
expect_failure escaping-link 'package archive contains an escaping link target' \
	"$fixtures/escaping-link/$package_name"
expect_failure module-link 'module tree contains a link in place of a module' \
	"$fixtures/module-link/$package_name"
expect_failure malformed-compression 'package contains malformed or truncated compressed content' \
	"$fixtures/malformed-compression/$package_name"
expect_failure trailing-xz-module 'XZ content contains bytes after its single stream' \
	"$fixtures/trailing-xz-module/$package_name"
expect_failure trailing-xz-data 'XZ content contains bytes after its single stream' \
	"$fixtures/trailing-xz-data/$package_name"
expect_failure huge-gnu-name 'tar archive metadata record exceeds the size limit' \
	"$fixtures/huge-gnu-name/$package_name"
expect_failure huge-pax-name 'PAX metadata is not supported in module packages' \
	"$fixtures/huge-pax-name/$package_name"
expect_failure nonzero-directory-bypass \
	'tar directory, symlink, or hardlink header has nonzero size' \
	"$fixtures/nonzero-directory-bypass/$package_name"
expect_failure nonzero-symlink-bypass \
	'tar directory, symlink, or hardlink header has nonzero size' \
	"$fixtures/nonzero-symlink-bypass/$package_name"
expect_failure nonzero-hardlink-bypass \
	'tar directory, symlink, or hardlink header has nonzero size' \
	"$fixtures/nonzero-hardlink-bypass/$package_name"
expect_failure pax-size-override 'PAX metadata is not supported in module packages' \
	"$fixtures/pax-size-override/$package_name"
expect_failure sparse 'tar archive contains an unsupported raw member type' \
	"$fixtures/sparse/$package_name"
expect_failure unsupported-type 'tar archive contains an unsupported raw member type' \
	"$fixtures/unsupported-type/$package_name"
expect_failure nested-gnu-metadata \
	'tar archive contains too many consecutive GNU metadata records' \
	"$fixtures/nested-gnu-metadata/$package_name"
expect_failure kernel-root-symlink 'module tree contains a link in place of a module' \
	"$fixtures/kernel-root-symlink/$package_name"
expect_failure kernel-root-hardlink 'module tree contains a link in place of a module' \
	"$fixtures/kernel-root-hardlink/$package_name"
expect_failure regular-ancestor 'data archive contains a non-directory member ancestor' \
	"$fixtures/regular-ancestor/$package_name"
expect_failure link-ancestor 'data archive contains a non-directory member ancestor' \
	"$fixtures/link-ancestor/$package_name"
expect_failure dangling-link 'data archive contains a dangling or chained link' \
	"$fixtures/dangling-link/$package_name"
expect_failure chained-link 'data archive contains a dangling or chained link' \
	"$fixtures/chained-link/$package_name"
expect_failure dangling-hardlink 'data archive contains a dangling or chained link' \
	"$fixtures/dangling-hardlink/$package_name"
expect_failure duplicate-ar 'package contains a duplicate ar member' \
	"$fixtures/duplicate-ar/$package_name"
expect_failure unexpected-ar 'package contains an unexpected ar member' \
	"$fixtures/unexpected-ar/$package_name"
expect_failure duplicate-role 'module package role appears more than once' \
	"$unsigned_deb" "$not_at_eof_deb"
expect_failure missing-modules 'the required modules package is missing' \
	"$extra_deb"
expect_failure wrong-role 'package control identity is not a supported arm64 module package' \
	"$fixtures/wrong-role/linux-image-7.2-rc5-jg-0sp11fixture1-qcom-x1e_7.2-rc5-jg-0sp11fixture1_arm64.deb"
expect_failure huge-ar 'debian-binary member must be exactly four bytes' \
	"$fixtures/huge-ar/$package_name"

cp "$unsigned_deb" "$results/wrong-name.deb"
expect_failure wrong-filename 'input filename does not match its package control identity' \
	"$results/wrong-name.deb"

ln -s "$unsigned_deb" "$results/input-link.deb"
expect_failure symlink-input 'input package could not be opened or read safely' \
	"$results/input-link.deb"

printf 'Module Deb scanner validated safe package structure, all module compression formats, exact EOF markers, counts, and hostile archive rejection.\n'
