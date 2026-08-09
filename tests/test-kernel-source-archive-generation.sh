#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
generator_script="$repo_dir/scripts/generate-sp11-kernel-source-archive.py"
validator="$repo_dir/scripts/validate-sp11-source-archive.py"
temporary_root=""
temporary_parent=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  chmod -R u+w "$temporary_root" 2>/dev/null || true
  case "$temporary_root" in
    "$temporary_parent/sp11-kernel-source-generation."*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected fixture path: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

run_generator() {
  "$python_path" -I "$generator_script" \
    --scratch-parent "${GENERATOR_SCRATCH_PARENT:-$scratch_parent}" "$@"
}

run_generator_with_ignored_sigchld() {
  "$python_path" -I -c '
import os
import signal
import sys

signal.signal(signal.SIGCHLD, signal.SIG_IGN)
os.execv(sys.argv[1], sys.argv[1:])
' "$python_path" -I "$generator_script" \
    --scratch-parent "${GENERATOR_SCRATCH_PARENT:-$scratch_parent}" "$@"
}

run_validator() {
  "$python_path" -I "$validator" "$@"
}

expect_failure() {
  local expected="$1" output="$2"
  shift 2
  if "$@" > "$temporary_root/failure.stdout" 2> "$temporary_root/failure.stderr"; then
    die "generator accepted hostile fixture: $expected"
  fi
  grep -Fqi "$expected" "$temporary_root/failure.stderr" ||
    die "hostile fixture failure did not mention: $expected"
  [ ! -e "$output" ] && [ ! -L "$output" ] ||
    die "failed generation left an output: $output"
}

wait_for_final_pause() {
  local output="$1" parent="$2" pid="$3" candidate nonzero
  for ((pause_attempt = 0; pause_attempt < 1500; pause_attempt++)); do
    if [ -s "$output" ]; then
      for candidate in "$parent"/.sp11-source-archive.*; do
        if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
          nonzero="$(find "$candidate" -type f ! -size 0 -print -quit)"
          if [ -z "$nonzero" ]; then
            printf '%s\n' "$candidate"
            return 0
          fi
        fi
      done
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.01
  done
  return 1
}

for tool in cp find git mkfifo python3 sed shasum xz; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -x "$generator_script" ] || die "missing executable source archive generator"
[ -x "$validator" ] || die "missing executable source archive validator"

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-kernel-source-generation.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
upstream_repo="$temporary_root/upstream"
source_repo="$temporary_root/source"
output_a="$temporary_root/output-a"
output_b="$temporary_root/output-b"
output_sigchld="$temporary_root/output-sigchld"
output_no_shallow="$temporary_root/output-no-shallow"
output_wrong_shallow="$temporary_root/output-wrong-shallow"
output_mixed_shallow="$temporary_root/output-mixed-shallow"
output_commit_graph="$temporary_root/output-commit-graph"
hostile_home="$temporary_root/hostile-home"
hostile_bin="$temporary_root/hostile-bin"
hostile_python="$temporary_root/hostile-python"
hostile_tmp="$source_repo/hostile-tmp"
scratch_parent="$temporary_root/scratch"
mkdir -p \
  "$upstream_repo" "$output_a" "$output_b" "$output_sigchld" "$output_no_shallow" \
  "$output_wrong_shallow" "$output_mixed_shallow" "$output_commit_graph" \
  "$hostile_home" "$hostile_bin" "$hostile_python" "$scratch_parent"

epoch=1700000000
git -C "$upstream_repo" init --quiet --initial-branch=fixture
git -C "$upstream_repo" config user.name 'SP11 source generator fixture'
git -C "$upstream_repo" config user.email 'sp11-source-generator@example.invalid'
printf 'fixture_function\nancestor source\nfixture_tail\n' > "$upstream_repo/source.c"
printf 'source.c diff=cpp\n' > "$upstream_repo/.gitattributes"
printf '*.generated\n' > "$upstream_repo/.gitignore"
mkdir "$upstream_repo/bulk"
for ((bulk_index = 0; bulk_index < 2000; bulk_index++)); do
  printf 'index fixture %04d\n' "$bulk_index" \
    > "$upstream_repo/bulk/file-$(printf '%04d' "$bulk_index")"
done
git -C "$upstream_repo" add .
GIT_AUTHOR_DATE="@$((epoch - 1)) +0000" \
  GIT_COMMITTER_DATE="@$((epoch - 1)) +0000" \
  git -C "$upstream_repo" commit --quiet -m 'Create unavailable shallow parent'
printf 'fixture_function\nbase source\nfixture_tail\n' > "$upstream_repo/source.c"
git -C "$upstream_repo" add source.c
GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
  git -C "$upstream_repo" commit --quiet -m 'Create source archive base'
source_parent="$(git -C "$upstream_repo" rev-parse 'HEAD^1^{commit}')"
git clone --quiet --depth=1 --branch=fixture \
  "file://$upstream_repo" "$source_repo"
git -C "$source_repo" config user.name 'SP11 source generator fixture'
git -C "$source_repo" config user.email 'sp11-source-generator@example.invalid'
mkdir "$hostile_tmp"
source_head="$(git -C "$source_repo" rev-parse 'HEAD^{commit}')"
[ "$(sed -n '1p' "$source_repo/.git/shallow")" = "$source_head" ] ||
  die "depth-1 fixture did not bind Source HEAD as its shallow boundary"
[ "$(wc -l < "$source_repo/.git/shallow" | tr -d ' ')" = 1 ] ||
  die "depth-1 fixture produced more than one shallow boundary"
if git -C "$source_repo" cat-file -e "$source_parent^{commit}" 2>/dev/null; then
  die "depth-1 fixture unexpectedly retained the source parent object"
fi

printf 'fixture_function\npatched source $Format:%%H$\nfixture_tail\n' > "$source_repo/source.c"
printf 'forced corresponding source\n' > "$source_repo/required.generated"
temporary_index="$temporary_root/capture.index"
rm -f -- "$temporary_index"
GIT_INDEX_FILE="$temporary_index" git -C "$source_repo" read-tree HEAD
GIT_INDEX_FILE="$temporary_index" git -C "$source_repo" add -A -f -- .
patched_tree="$(GIT_INDEX_FILE="$temporary_index" git -C "$source_repo" write-tree)"
canonical_diff="$temporary_root/canonical.diff"
LC_ALL=C GIT_EXTERNAL_DIFF= \
  git -C "$source_repo" -c core.attributesFile=/dev/null \
    -c diff.suppressBlankEmpty=false --attr-source="$patched_tree" \
    diff --binary --full-index \
    --no-ext-diff --no-textconv --no-color --diff-algorithm=myers \
    --indent-heuristic --unified=3 --inter-hunk-context=0 --no-renames \
    -O/dev/null --src-prefix=a/ --dst-prefix=b/ HEAD "$patched_tree" -- \
    > "$canonical_diff"
diff_sha256="$(shasum -a 256 "$canonical_diff" | awk '{print $1}')"
rm -f -- "$temporary_index"

# Deliberately diverge both the ordinary index and worktree after the builder's
# exact tree object was captured.  Generation must use the object, not either
# mutable view.
printf 'staged but not archived\n' > "$source_repo/source.c"
git -C "$source_repo" add source.c
printf 'worktree but not archived\n' > "$source_repo/source.c"
printf 'post-build output\n' > "$source_repo/build.generated"
source_status_before="$(git -C "$source_repo" status --porcelain=v1 --untracked-files=all)"
git -C "$source_repo" config tar.umask user

baseline="$temporary_root/baseline.env"
cat > "$baseline" <<EOF_BASELINE
SP11_KERNEL_BASELINE_ID="fixture"
SP11_KERNEL_UPSTREAM_URL="https://example.invalid/kernel.git"
SP11_KERNEL_UPSTREAM_REF="fixture"
SP11_KERNEL_UPSTREAM_COMMIT="$source_head"
SP11_KERNEL_SOURCE_DATE_EPOCH="$epoch"
EOF_BASELINE

git_version="$(LC_ALL=C git --version)"
xz_version="$(LC_ALL=C xz --version | sed -n '1p')"
python_path="$(python3 -c 'import sys; print(sys.executable)')"
git_path="$(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("git")))')"
xz_path="$(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("xz")))')"
xz_library_path="$(python3 - "$xz_path" <<'PY_XZ_LIBRARY'
import os
import platform
import subprocess
import sys

xz = sys.argv[1]
if platform.system() == "Darwin":
    output = subprocess.check_output(["otool", "-L", xz], text=True)
    candidates = [line.strip().split(" ", 1)[0] for line in output.splitlines()[1:]]
else:
    output = subprocess.check_output(["ldd", xz], text=True)
    candidates = [
        line.split("=>", 1)[1].strip().split(" ", 1)[0]
        for line in output.splitlines()
        if "liblzma" in line and "=>" in line
    ]
matches = [os.path.realpath(path) for path in candidates if "liblzma" in path]
if len(matches) != 1:
    raise SystemExit("could not resolve exactly one fixture XZ compression library")
print(matches[0])
PY_XZ_LIBRARY
)"
git_sha256="$(shasum -a 256 "$git_path" | awk '{print $1}')"
xz_sha256="$(shasum -a 256 "$xz_path" | awk '{print $1}')"
xz_library_sha256="$(shasum -a 256 "$xz_library_path" | awk '{print $1}')"
validator_sha256="$(shasum -a 256 "$validator" | awk '{print $1}')"
committed_contract="$repo_dir/config/kernel-source-archive-v1.env"
committed_validator_sha256="$(sed -n \
  's/^SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' \
  "$committed_contract")"
[ "$committed_validator_sha256" = "$validator_sha256" ] ||
  die "committed source-archive contract does not bind the exact validator bytes"
contract="$temporary_root/archive-contract.env"
cat > "$contract" <<EOF_CONTRACT
SP11_KERNEL_SOURCE_ARCHIVE_CONTRACT="sp11-kernel-source-archive-v1"
SP11_KERNEL_SOURCE_ARCHIVE_PYTHON_PATH="$python_path"
SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256="$validator_sha256"
SP11_KERNEL_SOURCE_ARCHIVE_GIT_PATH="$git_path"
SP11_KERNEL_SOURCE_ARCHIVE_GIT_SHA256="$git_sha256"
SP11_KERNEL_SOURCE_ARCHIVE_GIT_VERSION="$git_version"
SP11_KERNEL_SOURCE_ARCHIVE_XZ_PATH="$xz_path"
SP11_KERNEL_SOURCE_ARCHIVE_XZ_SHA256="$xz_sha256"
SP11_KERNEL_SOURCE_ARCHIVE_XZ_VERSION="$xz_version"
SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_PATH="$xz_library_path"
SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_SHA256="$xz_library_sha256"
EOF_CONTRACT

if "$python_path" "$generator_script" > "$temporary_root/nonisolated.log" 2>&1; then
  die "generator accepted a non-isolated Python invocation"
fi
grep -Fq 'Python isolated mode (-I)' "$temporary_root/nonisolated.log" ||
  die "non-isolated Python rejection was not explicit"

# A hostile parent may have inherited SIGCHLD=SIG_IGN.  The generator must
# restore waitable-child semantics before any tool launch, retain a real
# nonzero status even when stdout looks plausible, and never kill after reap.
if ! "$python_path" -I -c '
import importlib.util
import os
from pathlib import Path
import signal
import sys

generator_path = Path(sys.argv[1])
kill_marker = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "sp11_source_generator_sigchld_fixture", generator_path
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.require_release_signal_mask_support()
module.install_release_signal_handlers()
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
module.establish_child_reaping_contract()
assert signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL
captured = []
original_popen = module.subprocess.Popen

def recording_popen(*arguments, **keywords):
    child = original_popen(*arguments, **keywords)
    captured.append(child)
    child.kill = lambda: kill_marker.write_text("unsafe post-reap kill\n")
    return child

module.subprocess.Popen = recording_popen
try:
    module.run_text(
        [
            sys.executable,
            "-I",
            "-c",
            "import os; os.write(1, b\"plausible output\\n\"); raise SystemExit(7)",
        ],
        {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        "plausible nonzero child",
    )
except module.GenerationError as exc:
    assert "plausible nonzero child failed" in str(exc)
else:
    raise AssertionError("nonzero source-archive child was accepted")
finally:
    module.subprocess.Popen = original_popen
assert len(captured) == 1
child = captured[0]
assert child.returncode == 7
try:
    os.waitpid(child.pid, os.WNOHANG)
except ChildProcessError:
    pass
else:
    raise AssertionError("nonzero source-archive child was not exactly reaped")
assert not kill_marker.exists()

# The invariant is checked again at each spawn, not merely once at startup.
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
called = False

def forbidden_popen(*_arguments, **_keywords):
    global called
    called = True
    raise AssertionError("spawn occurred with ignored SIGCHLD")

module.subprocess.Popen = forbidden_popen
try:
    module.run_text(
        [sys.executable, "-I", "-c", "pass"],
        {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        "unwaitable child",
    )
except module.GenerationError as exc:
    assert "would not remain waitable" in str(exc)
else:
    raise AssertionError("per-spawn SIGCHLD invariant was not enforced")
assert not called

# A release signal queued after raw waitpid has reaped the child but before
# Popen.returncode registration must be delivered only after terminal owner
# state is visible. It must never authorize a kill of the reusable PID/PGID.
module.subprocess.Popen = original_popen
module.establish_child_reaping_contract()
wait_child = original_popen(
    [sys.executable, "-I", "-c", "pass"],
    stdout=module.subprocess.PIPE,
    stderr=module.subprocess.PIPE,
)
wait_kill_marker = kill_marker.with_name(kill_marker.name + "-wait")
wait_child.kill = lambda: wait_kill_marker.write_text("unsafe post-waitpid kill\n")

def raw_wait_then_signal(*_arguments, **_keywords):
    current_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    assert module.RELEASE_SIGNAL_SET <= current_mask
    waited_pid, status = os.waitpid(wait_child.pid, 0)
    assert waited_pid == wait_child.pid
    os.kill(os.getpid(), signal.SIGTERM)
    wait_child.returncode = os.waitstatus_to_exitcode(status)
    return wait_child.returncode

wait_child.wait = raw_wait_then_signal
try:
    module.wait_registered(wait_child)
except KeyboardInterrupt:
    pass
else:
    raise AssertionError("pending TERM was not delivered after wait registration")
assert wait_child.returncode == 0
try:
    os.waitpid(wait_child.pid, os.WNOHANG)
except ChildProcessError:
    pass
else:
    raise AssertionError("raw-wait source-archive child was not exactly reaped")
assert not wait_kill_marker.exists()
print("source-archive SIGCHLD child ownership fixtures passed")
' "$generator_script" "$temporary_root/sigchld-unsafe-kill" \
    > "$temporary_root/sigchld-owner.log" 2>&1; then
  sed -n '1,40p' "$temporary_root/sigchld-owner.log" >&2
  die "source-archive SIGCHLD child ownership fixture failed"
fi
grep -Fq 'source-archive SIGCHLD child ownership fixtures passed' \
  "$temporary_root/sigchld-owner.log" ||
  die "source-archive SIGCHLD fixture omitted its completion marker"

"$python_path" -I - "$generator_script" <<'PY_PRIVATE_GIT_CONFIG'
import runpy
import sys

module = runpy.run_path(sys.argv[1])
private_git_config = module["private_git_config"]
for object_format in ("sha1", "sha256"):
    lines = private_git_config(object_format).decode("ascii").splitlines()
    assert lines.count("\tcommitGraph = false") == 1, (object_format, lines)
PY_PRIVATE_GIT_CONFIG

manifest="$temporary_root/build-manifest.txt"
cat > "$manifest" <<EOF_MANIFEST
Provenance schema: sp11-kernel-build-v2
Release build: true
Source mode: git
Source URL: https://example.invalid/kernel.git
Source ref: fixture
Expected source commit: $source_head
Source HEAD: $source_head
Patched diff format: git-diff-full-index-binary-v1
Patched diff Git version: $git_version
Patched diff SHA256: $diff_sha256
Patched tree ID: $patched_tree
Build completed: true
EOF_MANIFEST

cat > "$hostile_home/.gitconfig" <<'EOF_GITCONFIG'
[core]
  attributesFile = /dev/null
[diff "hostile"]
  command = false
EOF_GITCONFIG
hostile_tool_marker="$temporary_root/hostile-tool-invoked"
cat > "$hostile_bin/git" <<EOF_HOSTILE_GIT
#!/bin/sh
printf 'hostile git invoked\n' >> '$hostile_tool_marker'
exit 91
EOF_HOSTILE_GIT
cat > "$hostile_bin/xz" <<EOF_HOSTILE_XZ
#!/bin/sh
printf 'hostile xz invoked\n' >> '$hostile_tool_marker'
exit 92
EOF_HOSTILE_XZ
chmod 755 "$hostile_bin/git" "$hostile_bin/xz"
hostile_python_marker="$temporary_root/hostile-python-imported"
cat > "$hostile_python/tarfile.py" <<EOF_HOSTILE_PYTHON
with open('$hostile_python_marker', 'w', encoding='utf-8') as marker:
    marker.write('hostile import\n')
raise RuntimeError('hostile tarfile imported; marker $hostile_python_marker')
EOF_HOSTILE_PYTHON
trace_victim="$temporary_root/trace-victim"
printf 'preserve trace victim\n' > "$trace_victim"
trace_victim_sha="$(shasum -a 256 "$trace_victim" | awk '{print $1}')"

archive_name="fixture-patched-source.tar.xz"
archive_a="$output_a/$archive_name"
archive_b="$output_b/$archive_name"
archive_sigchld="$output_sigchld/$archive_name"
mkdir "$temporary_root/cwd-a" "$temporary_root/cwd-b"
(
  umask 077
  cd "$temporary_root/cwd-a"
  PATH="$hostile_bin:$PATH" HOME="$hostile_home" TMPDIR="$hostile_tmp" \
    XDG_CONFIG_HOME="$hostile_home" PYTHONPATH="$hostile_python" \
    GIT_TRACE="$trace_victim" GIT_TRACE2_EVENT="$trace_victim" \
    GIT_DIFF_OPTS=-U99 LD_LIBRARY_PATH="$hostile_bin" \
    GIT_DIR="$source_repo/.git" GIT_INDEX_FILE="$source_repo/.git/index" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.attributesfile \
    GIT_CONFIG_VALUE_0=/dev/null XZ_DEFAULTS=--check=sha256 XZ_OPT=--threads=0 \
    run_generator \
      --baseline "$baseline" \
      --build-manifest "$manifest" \
      --source-repo "$source_repo" \
      --toolchain-contract "$contract" \
      --output "$archive_a" > "$temporary_root/generation-a.log"
)
[ ! -e "$hostile_tool_marker" ] || die "generator invoked a hostile PATH shim"
[ ! -e "$hostile_python_marker" ] || die "validator imported a hostile Python module"
[ "$(shasum -a 256 "$trace_victim" | awk '{print $1}')" = "$trace_victim_sha" ] ||
  die "Git tracing changed an attacker-selected victim path"
(
  umask 002
  cd "$temporary_root/cwd-b"
  HOME=/nonexistent TMPDIR="$output_a" XZ_DEFAULTS=--check=sha256 \
    run_generator \
      --baseline "$baseline" \
      --build-manifest "$manifest" \
      --source-repo "$source_repo" \
      --toolchain-contract "$contract" \
      --output "$archive_b" > "$temporary_root/generation-b.log"
)

run_generator_with_ignored_sigchld \
  --baseline "$baseline" \
  --build-manifest "$manifest" \
  --source-repo "$source_repo" \
  --toolchain-contract "$contract" \
  --output "$archive_sigchld" > "$temporary_root/generation-sigchld.log"

cmp -s "$archive_a" "$archive_b" ||
  die "repeated generation in distinct paths did not produce identical bytes"
cmp -s "$archive_a" "$archive_sigchld" ||
  die "inherited SIGCHLD disposition changed generated archive bytes"
archive_sha256="$(shasum -a 256 "$archive_a" | awk '{print $1}')"
grep -Fq "Archive SHA256: $archive_sha256" "$temporary_root/generation-a.log" ||
  die "generator did not report the exact output SHA-256"
grep -Fxq 'Corresponding-source legal sufficiency review required: true' \
  "$temporary_root/generation-a.log" ||
  die "generator did not require legal corresponding-source review"
grep -Fxq 'Publication authorized: false' "$temporary_root/generation-a.log" ||
  die "generator did not keep publication fail-closed"
grep -Fxq "Archive source epoch: $epoch" "$temporary_root/generation-a.log" ||
  die "independent exact-epoch validation was not reported"

# The generator's private history boundary is derived only from manifest Source
# HEAD.  A true depth-1 object store must remain usable even when its ambient
# .git/shallow authority is absent, and the resulting raw bytes must be exact.
source_shallow="$source_repo/.git/shallow"
saved_source_shallow="$temporary_root/source-shallow.saved"
mv "$source_shallow" "$saved_source_shallow"
archive_no_shallow="$output_no_shallow/$archive_name"
run_generator \
  --baseline "$baseline" \
  --build-manifest "$manifest" \
  --source-repo "$source_repo" \
  --toolchain-contract "$contract" \
  --output "$archive_no_shallow" > "$temporary_root/generation-no-shallow.log"
[ ! -e "$source_shallow" ] && [ ! -L "$source_shallow" ] ||
  die "generator recreated or consumed ambient shallow authority"
cmp -s "$archive_a" "$archive_no_shallow" ||
  die "absent ambient shallow authority changed generated archive bytes"
mv "$saved_source_shallow" "$source_shallow"

# Same-format and mixed-format ambient boundary tampering is never private Git
# authority.  Git may reject malformed source metadata during its read-only
# repository preflight; if it accepts it, output bytes must remain identical.
printf '%s\n' "$source_parent" > "$source_shallow"
archive_wrong_shallow="$output_wrong_shallow/$archive_name"
if run_generator \
    --baseline "$baseline" \
    --build-manifest "$manifest" \
    --source-repo "$source_repo" \
    --toolchain-contract "$contract" \
    --output "$archive_wrong_shallow" \
    > "$temporary_root/generation-wrong-shallow.stdout" \
    2> "$temporary_root/generation-wrong-shallow.stderr"; then
  cmp -s "$archive_a" "$archive_wrong_shallow" ||
    die "tampered ambient shallow boundary changed successful archive bytes"
else
  [ ! -s "$archive_wrong_shallow" ] ||
    die "tampered ambient shallow rejection left nonempty output bytes"
  ! grep -Fq 'Generated deterministic' \
    "$temporary_root/generation-wrong-shallow.stdout" ||
    die "tampered ambient shallow rejection emitted a success claim"
fi
[ "$(sed -n '1p' "$source_shallow")" = "$source_parent" ] ||
  die "generator changed the tampered ambient shallow boundary"

mixed_shallow="$(printf '0%.0s' {1..64})"
printf '%s\n' "$mixed_shallow" > "$source_shallow"
archive_mixed_shallow="$output_mixed_shallow/$archive_name"
if run_generator \
    --baseline "$baseline" \
    --build-manifest "$manifest" \
    --source-repo "$source_repo" \
    --toolchain-contract "$contract" \
    --output "$archive_mixed_shallow" \
    > "$temporary_root/generation-mixed-shallow.stdout" \
    2> "$temporary_root/generation-mixed-shallow.stderr"; then
  cmp -s "$archive_a" "$archive_mixed_shallow" ||
    die "mixed-format ambient shallow boundary changed successful archive bytes"
else
  [ ! -s "$archive_mixed_shallow" ] ||
    die "mixed-format ambient shallow rejection left nonempty output bytes"
  ! grep -Fq 'Generated deterministic' \
    "$temporary_root/generation-mixed-shallow.stdout" ||
    die "mixed-format ambient shallow rejection emitted a success claim"
fi
[ "$(sed -n '1p' "$source_shallow")" = "$mixed_shallow" ] ||
  die "generator changed the mixed-format ambient shallow boundary"
printf '%s\n' "$source_head" > "$source_shallow"

# Alternate object storage may contain an ambient commit-graph cache with its
# own commit date/tree/parent metadata.  Source-local config keeps the read-only
# source preflight independent of this deliberately corrupt cache; the private
# object view must independently disable commit-graph authority and reproduce
# the exact archive bytes from raw objects.
git -C "$upstream_repo" commit-graph write --reachable
upstream_commit_graph="$upstream_repo/.git/objects/info/commit-graph"
source_commit_graph="$source_repo/.git/objects/info/commit-graph"
[ -f "$upstream_commit_graph" ] && [ ! -L "$upstream_commit_graph" ] ||
  die "full-history fixture did not create a regular commit-graph cache"
cp "$upstream_commit_graph" "$source_commit_graph"
[ -f "$source_commit_graph" ] && [ ! -L "$source_commit_graph" ] ||
  die "commit-graph fixture did not create a regular cache file"
chmod u+w "$source_commit_graph"
python3 - "$source_commit_graph" <<'PY_CORRUPT_COMMIT_GRAPH'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
assert len(data) > 20
data[-1] ^= 0x01
path.write_bytes(data)
PY_CORRUPT_COMMIT_GRAPH
source_commit_graph_sha="$(shasum -a 256 "$source_commit_graph" | awk '{print $1}')"
git -C "$source_repo" config core.commitGraph false
archive_commit_graph="$output_commit_graph/$archive_name"
run_generator \
  --baseline "$baseline" \
  --build-manifest "$manifest" \
  --source-repo "$source_repo" \
  --toolchain-contract "$contract" \
  --output "$archive_commit_graph" > "$temporary_root/generation-commit-graph.log"
cmp -s "$archive_a" "$archive_commit_graph" ||
  die "ambient source commit-graph changed generated archive bytes"
[ "$(shasum -a 256 "$source_commit_graph" | awk '{print $1}')" = \
  "$source_commit_graph_sha" ] || die "generator changed the ambient commit-graph cache"
git -C "$source_repo" config --unset-all core.commitGraph
rm -f -- "$source_commit_graph"

# A private shallow boundary waives traversal beyond Source HEAD; it never
# waives the exact bound commit object itself.  Point an isolated fixture copy
# at a canonical but unavailable commit and bind baseline/manifest to it.
missing_head="$(printf '1%.0s' {1..40})"
if git -C "$source_repo" cat-file -e "$missing_head^{commit}" 2>/dev/null; then
  die "missing-HEAD fixture unexpectedly resolved its absent commit"
fi
missing_head_repo="$temporary_root/missing-head-source"
cp -R "$source_repo" "$missing_head_repo"
missing_head_ref="$(git -C "$missing_head_repo" symbolic-ref HEAD)"
case "$missing_head_ref" in
  refs/heads/*) ;;
  *) die "missing-HEAD fixture resolved an unsafe symbolic ref" ;;
esac
printf '%s\n' "$missing_head" > "$missing_head_repo/.git/$missing_head_ref"
printf '%s\n' "$missing_head" > "$missing_head_repo/.git/shallow"
missing_head_baseline="$temporary_root/missing-head-baseline.env"
sed "s/SP11_KERNEL_UPSTREAM_COMMIT=\"$source_head\"/SP11_KERNEL_UPSTREAM_COMMIT=\"$missing_head\"/" \
  "$baseline" > "$missing_head_baseline"
missing_head_manifest="$temporary_root/missing-head-manifest.txt"
sed \
  -e "s/^Expected source commit: $source_head$/Expected source commit: $missing_head/" \
  -e "s/^Source HEAD: $source_head$/Source HEAD: $missing_head/" \
  "$manifest" > "$missing_head_manifest"
expect_failure 'source HEAD check failed' \
  "$output_a/missing-head-patched-source.tar.xz" \
  run_generator --baseline "$missing_head_baseline" \
  --build-manifest "$missing_head_manifest" \
  --source-repo "$missing_head_repo" --toolchain-contract "$contract" \
  --output "$output_a/missing-head-patched-source.tar.xz"

# A syntactically valid commit whose exact tree object is absent must also fail.
# hash-object writes only the commit object; the referenced tree stays missing.
missing_head_tree="$(printf '2%.0s' {1..40})"
if git -C "$source_repo" cat-file -e "$missing_head_tree^{tree}" 2>/dev/null; then
  die "missing-HEAD-tree fixture unexpectedly resolved its absent tree"
fi
missing_head_tree_repo="$temporary_root/missing-head-tree-source"
cp -R "$source_repo" "$missing_head_tree_repo"
missing_head_tree_content="$temporary_root/missing-head-tree.commit"
cat > "$missing_head_tree_content" <<EOF_MISSING_HEAD_TREE
tree $missing_head_tree
author SP11 source generator fixture <sp11-source-generator@example.invalid> $epoch +0000
committer SP11 source generator fixture <sp11-source-generator@example.invalid> $epoch +0000

Bind a deliberately unavailable tree
EOF_MISSING_HEAD_TREE
synthetic_head="$(git -C "$missing_head_tree_repo" \
  hash-object -t commit -w "$missing_head_tree_content")"
missing_head_tree_ref="$(git -C "$missing_head_tree_repo" symbolic-ref HEAD)"
case "$missing_head_tree_ref" in
  refs/heads/*) ;;
  *) die "missing-HEAD-tree fixture resolved an unsafe symbolic ref" ;;
esac
printf '%s\n' "$synthetic_head" \
  > "$missing_head_tree_repo/.git/$missing_head_tree_ref"
printf '%s\n' "$synthetic_head" > "$missing_head_tree_repo/.git/shallow"
if git -C "$missing_head_tree_repo" cat-file -e "$synthetic_head^{tree}" 2>/dev/null; then
  die "synthetic Source HEAD unexpectedly resolved its unavailable tree"
fi
missing_head_tree_baseline="$temporary_root/missing-head-tree-baseline.env"
sed "s/SP11_KERNEL_UPSTREAM_COMMIT=\"$source_head\"/SP11_KERNEL_UPSTREAM_COMMIT=\"$synthetic_head\"/" \
  "$baseline" > "$missing_head_tree_baseline"
missing_head_tree_manifest="$temporary_root/missing-head-tree-manifest.txt"
sed \
  -e "s/^Expected source commit: $source_head$/Expected source commit: $synthetic_head/" \
  -e "s/^Source HEAD: $source_head$/Source HEAD: $synthetic_head/" \
  "$manifest" > "$missing_head_tree_manifest"
missing_head_tree_output="$output_a/missing-head-tree-patched-source.tar.xz"
if run_generator --baseline "$missing_head_tree_baseline" \
    --build-manifest "$missing_head_tree_manifest" \
    --source-repo "$missing_head_tree_repo" --toolchain-contract "$contract" \
    --output "$missing_head_tree_output" \
    > "$temporary_root/missing-head-tree.stdout" \
    2> "$temporary_root/missing-head-tree.stderr"; then
  die "generator accepted a Source HEAD with an unavailable tree object"
fi
[ ! -s "$missing_head_tree_output" ] ||
  die "missing Source HEAD tree failure left nonempty output bytes"
! grep -Fq 'Generated deterministic' "$temporary_root/missing-head-tree.stdout" ||
  die "missing Source HEAD tree failure emitted a success claim"
grep -Fq 'error:' "$temporary_root/missing-head-tree.stderr" ||
  die "missing Source HEAD tree failure was not explicit"
! grep -Fq 'Traceback' "$temporary_root/missing-head-tree.stderr" ||
  die "missing Source HEAD tree failure leaked a traceback"

# The patched tree is an independent bound object and must exist even though
# Source HEAD is intentionally shallow.
missing_patched_tree="$(printf '3%.0s' {1..40})"
if git -C "$source_repo" cat-file -e "$missing_patched_tree^{tree}" 2>/dev/null; then
  die "missing-patched-tree fixture unexpectedly resolved its absent tree"
fi
missing_patched_tree_manifest="$temporary_root/missing-patched-tree-manifest.txt"
sed "s/^Patched tree ID: $patched_tree$/Patched tree ID: $missing_patched_tree/" \
  "$manifest" > "$missing_patched_tree_manifest"
expect_failure 'patched-tree type check failed' \
  "$output_a/missing-patched-tree-patched-source.tar.xz" \
  run_generator --baseline "$baseline" \
  --build-manifest "$missing_patched_tree_manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/missing-patched-tree-patched-source.tar.xz"

python3 - "$archive_a" "$epoch" "$archive_name" <<'PY_VERIFY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
epoch = int(sys.argv[2])
expected_root = sys.argv[3][:-len(".tar.xz")]
with tarfile.open(archive, "r:xz") as source:
    members = source.getmembers()
assert members
assert {member.mtime for member in members} == {epoch}
assert members[0].name.rstrip("/") == expected_root
assert all(member.uid == 0 and member.gid == 0 for member in members)
PY_VERIFY

run_validator kernel \
  --archive "$archive_a" \
  --expected-tree "$patched_tree" \
  --expected-mtime "$epoch" > "$temporary_root/validator.log"
if run_validator kernel \
    --archive "$archive_a" \
    --expected-tree "$patched_tree" \
    --expected-mtime "$((epoch + 1))" \
    > "$temporary_root/wrong-mtime.log" 2>&1; then
  die "validator accepted archive metadata for the wrong source epoch"
fi
grep -Fqi 'timestamp does not match' "$temporary_root/wrong-mtime.log" ||
  die "wrong source epoch failure was not explicit"
for invalid_epoch in "+$epoch" " $epoch" "$epoch "; do
  if run_validator kernel \
      --archive "$archive_a" \
      --expected-tree "$patched_tree" \
      --expected-mtime "$invalid_epoch" \
      > "$temporary_root/noncanonical-epoch.log" 2>&1; then
    die "validator accepted a signed or whitespace-padded source epoch"
  fi
done

[ "$(git -C "$source_repo" status --porcelain=v1 --untracked-files=all)" = \
  "$source_status_before" ] || die "generation mutated the source index or worktree"
python3 - "$scratch_parent" <<'PY_SCRATCH_ROOTS'
import pathlib
import stat
import sys

parent = pathlib.Path(sys.argv[1])
assert not list(parent.glob(".sp11-source-archive-tomb.*"))
for scratch in parent.glob(".sp11-source-archive.*"):
    metadata = scratch.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
    assert stat.S_IMODE(metadata.st_mode) == 0o700
    members = list(scratch.rglob("*"))
    assert len(members) <= 32
    for member in members:
        member_metadata = member.lstat()
        assert not stat.S_ISLNK(member_metadata.st_mode)
        assert stat.S_ISDIR(member_metadata.st_mode) or (
            stat.S_ISREG(member_metadata.st_mode) and member_metadata.st_size == 0
        ), (member, oct(member_metadata.st_mode), member_metadata.st_size)
PY_SCRATCH_ROOTS

expect_failure 'changed after validation' \
  "$output_a/mutated-validated-patched-source.tar.xz" \
  run_generator --fixture-mutate-validated-archive \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/mutated-validated-patched-source.tar.xz"

expect_failure 'interrupted safely' \
  "$output_a/interrupted-validator-patched-source.tar.xz" \
  run_generator --fixture-interrupt-validator-child \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/interrupted-validator-patched-source.tar.xz"
interrupted_child_pid="$(sed -n \
  's/^Fixture source-archive child reaped PID: \([0-9][0-9]*\)$/\1/p' \
  "$temporary_root/failure.stderr")"
[ -n "$interrupted_child_pid" ] ||
  die "post-Popen SIGINT fixture did not report its reaped child"
if kill -0 "$interrupted_child_pid" 2>/dev/null; then
  die "post-Popen SIGINT fixture left its child process alive"
fi
! grep -Fq 'Generated deterministic' "$temporary_root/failure.stdout" ||
  die "post-Popen SIGINT fixture emitted a success claim"

for release_signal in HUP TERM; do
  for delivery in pending delivered; do
    child_signal_output="$output_a/validator-${delivery}-${release_signal}-patched-source.tar.xz"
    child_signal_stdout="$temporary_root/validator-${delivery}-${release_signal}.stdout"
    child_signal_stderr="$temporary_root/validator-${delivery}-${release_signal}.stderr"
    if run_generator "--fixture-${delivery}-signal-validator-child" "$release_signal" \
        --baseline "$baseline" --build-manifest "$manifest" \
        --source-repo "$source_repo" --toolchain-contract "$contract" \
        --output "$child_signal_output" \
        > "$child_signal_stdout" 2> "$child_signal_stderr"; then
      die "generator accepted $delivery $release_signal during child ownership"
    fi
    grep -Fqi 'interrupted safely' "$child_signal_stderr" ||
      die "$delivery $release_signal child interruption was not explicit"
    child_signal_pid="$(sed -n \
      's/^Fixture source-archive child reaped PID: \([0-9][0-9]*\)$/\1/p' \
      "$child_signal_stderr")"
    [ -n "$child_signal_pid" ] ||
      die "$delivery $release_signal child fixture did not report exact reap"
    if kill -0 "$child_signal_pid" 2>/dev/null; then
      die "$delivery $release_signal child fixture left its process alive"
    fi
    [ ! -e "$child_signal_output" ] && [ ! -L "$child_signal_output" ] ||
      die "$delivery $release_signal child fixture installed an output"
    ! grep -Fq 'Generated deterministic' "$child_signal_stdout" ||
      die "$delivery $release_signal child fixture emitted success"
  done
done

# Exercise the same ownership fences on a child whose stdout is the exact
# creation-owned raw-tar FD. The delivered case waits for nonzero bytes while
# the Git writer is still live; cleanup must reap it and truncate+fsync every
# retained scratch file before the failure returns.
for release_signal in HUP TERM; do
  for delivery in pending delivered; do
    writer_signal_output="$output_a/writer-${delivery}-${release_signal}-patched-source.tar.xz"
    writer_signal_stdout="$temporary_root/writer-${delivery}-${release_signal}.stdout"
    writer_signal_stderr="$temporary_root/writer-${delivery}-${release_signal}.stderr"
    if run_generator "--fixture-${delivery}-signal-writer-child" "$release_signal" \
        --baseline "$baseline" --build-manifest "$manifest" \
        --source-repo "$source_repo" --toolchain-contract "$contract" \
        --output "$writer_signal_output" \
        > "$writer_signal_stdout" 2> "$writer_signal_stderr"; then
      die "generator accepted $delivery $release_signal from an owned-file writer"
    fi
    if [ "$delivery" = delivered ]; then
      grep -Fq "Fixture source-archive writer signal delivered: SIG$release_signal" \
        "$writer_signal_stderr" ||
        die "delivered $release_signal writer fixture never observed an active writer"
    fi
    writer_signal_pid="$(sed -n \
      's/^Fixture source-archive writer child reaped PID: \([0-9][0-9]*\)$/\1/p' \
      "$writer_signal_stderr")"
    [ -n "$writer_signal_pid" ] ||
      die "$delivery $release_signal writer fixture did not report exact reap"
    if kill -0 "$writer_signal_pid" 2>/dev/null; then
      die "$delivery $release_signal writer fixture left its child alive"
    fi
    grep -Fqi 'interrupted safely' "$writer_signal_stderr" ||
      die "$delivery $release_signal writer interruption was not explicit"
    [ ! -e "$writer_signal_output" ] && [ ! -L "$writer_signal_output" ] ||
      die "$delivery $release_signal writer fixture installed an output"
    ! grep -Fq 'Generated deterministic' "$writer_signal_stdout" ||
      die "$delivery $release_signal writer fixture emitted success"
  done
done

unexpected_output="$output_a/unexpected-copy-patched-source.tar.xz"
if run_generator --fixture-raise-after-destination-copy \
    --baseline "$baseline" --build-manifest "$manifest" \
    --source-repo "$source_repo" --toolchain-contract "$contract" \
    --output "$unexpected_output" \
    > "$temporary_root/unexpected-copy.stdout" \
    2> "$temporary_root/unexpected-copy.stderr"; then
  die "generator accepted an unexpected destination-copy exception"
fi
[ -f "$unexpected_output" ] && [ ! -s "$unexpected_output" ] ||
  die "unexpected destination-copy exception was not scrubbed to zero bytes"
grep -Fq 'failed safely (RuntimeError)' "$temporary_root/unexpected-copy.stderr" ||
  die "unexpected destination-copy exception was not sanitized"
! grep -Fq 'Traceback' "$temporary_root/unexpected-copy.stderr" ||
  die "unexpected destination-copy exception leaked a traceback"

# Queue SIGINT after the exclusive install has produced its exact held output,
# but before the resource-producing call can transfer ownership to its caller.
# The blocked critical section must register the descriptor first, then deliver
# the pending interruption and scrub that exact inode without a success claim.
transfer_sigint_output="$output_a/transfer-sigint-patched-source.tar.xz"
transfer_sigint_victim="$temporary_root/transfer-sigint-victim"
printf 'preserve transfer SIGINT victim\n' > "$transfer_sigint_victim"
transfer_sigint_victim_sha="$(shasum -a 256 "$transfer_sigint_victim" | awk '{print $1}')"
if run_generator --fixture-sigint-before-install-transfer \
    --baseline "$baseline" --build-manifest "$manifest" \
    --source-repo "$source_repo" --toolchain-contract "$contract" \
    --output "$transfer_sigint_output" \
    > "$temporary_root/transfer-sigint.stdout" \
    2> "$temporary_root/transfer-sigint.stderr"; then
  die "generator accepted SIGINT during install ownership transfer"
fi
grep -Fqi 'interrupted safely' "$temporary_root/transfer-sigint.stderr" ||
  die "install-transfer SIGINT failure was not explicit"
! grep -Fq 'Generated deterministic' "$temporary_root/transfer-sigint.stdout" ||
  die "install-transfer SIGINT emitted a success claim"
[ -f "$transfer_sigint_output" ] && [ ! -L "$transfer_sigint_output" ] &&
  [ ! -s "$transfer_sigint_output" ] ||
  die "install-transfer SIGINT did not scrub the exact output inode"
[ "$(shasum -a 256 "$transfer_sigint_victim" | awk '{print $1}')" = \
  "$transfer_sigint_victim_sha" ] || die "install-transfer SIGINT changed a victim"

for release_signal in HUP TERM; do
  for delivery in pending delivered; do
    install_signal_output="$output_a/install-${delivery}-${release_signal}-patched-source.tar.xz"
    install_signal_stdout="$temporary_root/install-${delivery}-${release_signal}.stdout"
    install_signal_stderr="$temporary_root/install-${delivery}-${release_signal}.stderr"
    install_signal_victim="$temporary_root/install-${delivery}-${release_signal}-victim"
    printf 'preserve install signal victim\n' > "$install_signal_victim"
    install_signal_victim_sha="$(shasum -a 256 "$install_signal_victim" | awk '{print $1}')"
    if [ "$delivery" = pending ]; then
      install_signal_option=--fixture-pending-signal-before-install-registration
      install_signal_marker='Fixture source-archive install registration signal queued:'
    else
      install_signal_option=--fixture-delivered-signal-during-install
      install_signal_marker='Fixture source-archive install signal delivered:'
    fi
    if run_generator "$install_signal_option" "$release_signal" \
        --baseline "$baseline" --build-manifest "$manifest" \
        --source-repo "$source_repo" --toolchain-contract "$contract" \
        --output "$install_signal_output" \
        > "$install_signal_stdout" 2> "$install_signal_stderr"; then
      die "generator accepted $delivery $release_signal during install ownership"
    fi
    grep -Fq "$install_signal_marker SIG$release_signal" "$install_signal_stderr" ||
      die "$delivery $release_signal install fixture did not trigger exactly"
    grep -Fqi 'interrupted safely' "$install_signal_stderr" ||
      die "$delivery $release_signal install interruption was not explicit"
    [ -f "$install_signal_output" ] && [ ! -L "$install_signal_output" ] &&
      [ ! -s "$install_signal_output" ] ||
      die "$delivery $release_signal install output was not scrubbed to zero"
    [ "$(shasum -a 256 "$install_signal_victim" | awk '{print $1}')" = \
      "$install_signal_victim_sha" ] ||
      die "$delivery $release_signal install fixture changed a victim"
    ! grep -Fq 'Generated deterministic' "$install_signal_stdout" ||
      die "$delivery $release_signal install fixture emitted success"
  done

  final_signal_output="$output_a/final-${release_signal}-patched-source.tar.xz"
  final_signal_stdout="$temporary_root/final-${release_signal}.stdout"
  final_signal_stderr="$temporary_root/final-${release_signal}.stderr"
  if run_generator --fixture-signal-before-final-commit "$release_signal" \
      --baseline "$baseline" --build-manifest "$manifest" \
      --source-repo "$source_repo" --toolchain-contract "$contract" \
      --output "$final_signal_output" \
      > "$final_signal_stdout" 2> "$final_signal_stderr"; then
    die "generator accepted pending $release_signal at the terminal commit fence"
  fi
  grep -Fq "Fixture source-archive final signal queued: SIG$release_signal" \
    "$final_signal_stderr" ||
    die "terminal $release_signal fixture did not reach the exact final fence"
  grep -Fqi 'interrupted safely' "$final_signal_stderr" ||
    die "terminal $release_signal interruption was not explicit"
  [ -f "$final_signal_output" ] && [ ! -L "$final_signal_output" ] &&
    [ ! -s "$final_signal_output" ] ||
    die "terminal $release_signal output was not scrubbed to zero"
  ! grep -Fq 'Generated deterministic' "$final_signal_stdout" ||
    die "terminal $release_signal fixture emitted success"
done

python3 - "$scratch_parent" <<'PY_SIGNAL_SCRATCH'
import pathlib
import stat
import sys

parent = pathlib.Path(sys.argv[1])
for scratch in parent.glob(".sp11-source-archive.*"):
    metadata = scratch.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
    entries = list(scratch.rglob("*"))
    assert len(entries) <= 32
    for entry in entries:
        entry_metadata = entry.lstat()
        assert not stat.S_ISLNK(entry_metadata.st_mode)
        assert stat.S_ISDIR(entry_metadata.st_mode) or (
            stat.S_ISREG(entry_metadata.st_mode) and entry_metadata.st_size == 0
        ), (entry, oct(entry_metadata.st_mode), entry_metadata.st_size)
PY_SIGNAL_SCRATCH

destination_drift_output="$output_a/destination-drift-patched-source.tar.xz"
run_generator --fixture-pause-after-destination-copy \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$destination_drift_output" \
  > "$temporary_root/destination-drift.stdout" \
  2> "$temporary_root/destination-drift.stderr" &
destination_drift_pid=$!
for ((destination_attempt = 0; destination_attempt < 1000; destination_attempt++)); do
  [ -s "$destination_drift_output" ] && break
  kill -0 "$destination_drift_pid" 2>/dev/null || break
  sleep 0.01
done
[ -s "$destination_drift_output" ] || {
  wait "$destination_drift_pid" 2>/dev/null || true
  die "could not observe destination copy before its mapping check"
}
destination_drift_owned="$temporary_root/destination-drift-owned"
mv "$destination_drift_output" "$destination_drift_owned"
printf 'preserve destination drift victim\n' > "$destination_drift_output"
destination_drift_victim_sha="$(shasum -a 256 "$destination_drift_output" | awk '{print $1}')"
if wait "$destination_drift_pid"; then
  die "generator accepted a changed destination mapping"
fi
grep -Fqi 'destination mapping' "$temporary_root/destination-drift.stderr" ||
  die "destination mapping drift failure was not explicit"
[ ! -s "$destination_drift_owned" ] ||
  die "creation-owned drifted destination was not scrubbed"
[ "$(shasum -a 256 "$destination_drift_output" | awk '{print $1}')" = \
  "$destination_drift_victim_sha" ] || die "destination drift victim changed"

# Delay only after cwd restoration and scratch scrubbing.  A final output-name
# substitution must still prevent success and scrub only the held created inode.
late_name_output="$output_a/late-name-drift-patched-source.tar.xz"
run_generator --fixture-pause-before-final-mapping-check \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$late_name_output" \
  > "$temporary_root/late-name-drift.stdout" \
  2> "$temporary_root/late-name-drift.stderr" &
late_name_pid=$!
late_name_scratch="$(wait_for_final_pause \
  "$late_name_output" "$scratch_parent" "$late_name_pid")" || {
  wait "$late_name_pid" 2>/dev/null || true
  die "could not observe the late output-name finalization pause"
}
[ -d "$late_name_scratch" ] || die "late output-name fixture lost its scratch root"
late_name_owned="$temporary_root/late-name-owned"
mv "$late_name_output" "$late_name_owned"
printf 'preserve late output-name victim\n' > "$late_name_output"
late_name_victim_sha="$(shasum -a 256 "$late_name_output" | awk '{print $1}')"
if wait "$late_name_pid"; then
  die "generator accepted late output-name drift"
fi
grep -Fqi 'destination mapping' "$temporary_root/late-name-drift.stderr" ||
  die "late output-name drift failure was not explicit"
! grep -Fq 'Generated deterministic' "$temporary_root/late-name-drift.stdout" ||
  die "late output-name drift emitted a success claim"
[ ! -s "$late_name_owned" ] || die "late drifted output inode was not scrubbed"
[ "$(shasum -a 256 "$late_name_output" | awk '{print $1}')" = \
  "$late_name_victim_sha" ] || die "late output-name victim changed"

# Replacing the requested output parent after install must likewise fail at the
# final held-parent check without touching the replacement's victim entry.
late_parent_container="$temporary_root/late-parent-container"
late_parent_dir="$late_parent_container/requested"
mkdir -p "$late_parent_dir"
late_parent_output="$late_parent_dir/late-parent-drift-patched-source.tar.xz"
run_generator --fixture-pause-before-final-mapping-check \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$late_parent_output" \
  > "$temporary_root/late-parent-drift.stdout" \
  2> "$temporary_root/late-parent-drift.stderr" &
late_parent_pid=$!
wait_for_final_pause "$late_parent_output" "$scratch_parent" "$late_parent_pid" \
  > "$temporary_root/late-parent-scratch-name" || {
  wait "$late_parent_pid" 2>/dev/null || true
  die "could not observe the late output-parent finalization pause"
}
late_parent_owned="$late_parent_container/creation-owned"
mv "$late_parent_dir" "$late_parent_owned"
mkdir "$late_parent_dir"
printf 'preserve late output-parent victim\n' > "$late_parent_output"
late_parent_victim_sha="$(shasum -a 256 "$late_parent_output" | awk '{print $1}')"
if wait "$late_parent_pid"; then
  die "generator accepted late output-parent drift"
fi
grep -Fqi 'output parent' "$temporary_root/late-parent-drift.stderr" ||
  die "late output-parent drift failure was not explicit"
! grep -Fq 'Generated deterministic' "$temporary_root/late-parent-drift.stdout" ||
  die "late output-parent drift emitted a success claim"
[ ! -s "$late_parent_owned/late-parent-drift-patched-source.tar.xz" ] ||
  die "output under the drifted held parent was not scrubbed"
[ "$(shasum -a 256 "$late_parent_output" | awk '{print $1}')" = \
  "$late_parent_victim_sha" ] || die "late output-parent victim changed"

# A root-name replacement after the retained tree was scrubbed must be caught
# while the exact scratch root and parent descriptors are still held.
late_scratch_parent="$temporary_root/late-scratch-parent"
late_scratch_output_dir="$temporary_root/late-scratch-output"
mkdir "$late_scratch_parent" "$late_scratch_output_dir"
late_scratch_output="$late_scratch_output_dir/late-scratch-drift-patched-source.tar.xz"
GENERATOR_SCRATCH_PARENT="$late_scratch_parent" run_generator \
  --fixture-pause-before-final-mapping-check \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$late_scratch_output" \
  > "$temporary_root/late-scratch-drift.stdout" \
  2> "$temporary_root/late-scratch-drift.stderr" &
late_scratch_pid=$!
late_scratch_root="$(wait_for_final_pause \
  "$late_scratch_output" "$late_scratch_parent" "$late_scratch_pid")" || {
  wait "$late_scratch_pid" 2>/dev/null || true
  die "could not observe the late scratch-root finalization pause"
}
late_scratch_owned="$late_scratch_root.creation-owned"
mv "$late_scratch_root" "$late_scratch_owned"
mkdir -m 700 "$late_scratch_root"
late_scratch_victim="$late_scratch_root/preserve-victim"
printf 'preserve late scratch-root victim\n' > "$late_scratch_victim"
late_scratch_victim_sha="$(shasum -a 256 "$late_scratch_victim" | awk '{print $1}')"
if wait "$late_scratch_pid"; then
  die "generator accepted late scratch-root drift"
fi
grep -Fqi 'private scratch' "$temporary_root/late-scratch-drift.stderr" ||
  die "late scratch-root drift failure was not explicit"
! grep -Fq 'Generated deterministic' "$temporary_root/late-scratch-drift.stdout" ||
  die "late scratch-root drift emitted a success claim"
[ -f "$late_scratch_output" ] && [ ! -s "$late_scratch_output" ] ||
  die "late scratch-root failure did not scrub the held output inode"
[ "$(shasum -a 256 "$late_scratch_victim" | awk '{print $1}')" = \
  "$late_scratch_victim_sha" ] || die "late scratch-root victim changed"

wrong_diff_manifest="$temporary_root/wrong-diff-manifest.txt"
sed "s/^Patched diff SHA256: .*/Patched diff SHA256: $(printf '0%.0s' {1..64})/" \
  "$manifest" > "$wrong_diff_manifest"
expect_failure 'does not reproduce Patched diff SHA256' "$output_a/wrong-diff-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$wrong_diff_manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/wrong-diff-patched-source.tar.xz"

# A residual source-local diff driver can make a non-private builder capture
# differ.  The generator's private object view is authoritative and must reject
# that manifest instead of accepting alternate archive bytes.
hostile_diff="$temporary_root/hostile-driver.diff"
git -C "$source_repo" config diff.cpp.binary true
LC_ALL=C GIT_EXTERNAL_DIFF= \
  git -C "$source_repo" -c core.attributesFile=/dev/null \
    -c diff.suppressBlankEmpty=false --attr-source="$patched_tree" \
    diff --binary --full-index \
    --no-ext-diff --no-textconv --no-color --diff-algorithm=myers \
    --indent-heuristic --unified=3 --inter-hunk-context=0 --no-renames \
    -O/dev/null --src-prefix=a/ --dst-prefix=b/ HEAD "$patched_tree" -- \
    > "$hostile_diff"
git -C "$source_repo" config --unset-all diff.cpp.binary
hostile_diff_sha256="$(shasum -a 256 "$hostile_diff" | awk '{print $1}')"
[ "$hostile_diff_sha256" != "$diff_sha256" ] ||
  die "hostile local diff-driver fixture did not change the captured digest"
hostile_diff_manifest="$temporary_root/hostile-diff-manifest.txt"
sed "s/^Patched diff SHA256: .*/Patched diff SHA256: $hostile_diff_sha256/" \
  "$manifest" > "$hostile_diff_manifest"
diff_driver_victim="$temporary_root/diff-driver-victim"
printf 'preserve diff driver victim\n' > "$diff_driver_victim"
diff_driver_victim_sha="$(shasum -a 256 "$diff_driver_victim" | awk '{print $1}')"
expect_failure 'does not reproduce Patched diff SHA256' \
  "$output_a/hostile-driver-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$hostile_diff_manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/hostile-driver-patched-source.tar.xz"
[ "$(shasum -a 256 "$diff_driver_victim" | awk '{print $1}')" = \
  "$diff_driver_victim_sha" ] || die "diff-driver rejection changed a victim"

printf 'source.c export-ignore\n' > "$source_repo/.git/info/attributes"
expect_failure 'private attributes' \
  "$output_a/info-attributes-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/info-attributes-patched-source.tar.xz"
printf 'source.c export-subst\n' > "$source_repo/.git/info/attributes"
expect_failure 'private attributes' \
  "$output_a/info-subst-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/info-subst-patched-source.tar.xz"
rm -f -- "$source_repo/.git/info/attributes"

printf '%s\n' "$temporary_root/untrusted-object-store" \
  > "$source_repo/.git/objects/info/alternates"
expect_failure 'object alternates' "$output_a/alternates-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/alternates-patched-source.tar.xz"
rm -f -- "$source_repo/.git/objects/info/alternates"

wrong_epoch_baseline="$temporary_root/wrong-epoch.env"
sed "s/SOURCE_DATE_EPOCH=\"$epoch\"/SOURCE_DATE_EPOCH=\"$((epoch + 1))\"/" \
  "$baseline" > "$wrong_epoch_baseline"
expect_failure 'does not match the bound source commit' "$output_a/wrong-epoch-patched-source.tar.xz" \
  run_generator --baseline "$wrong_epoch_baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$output_a/wrong-epoch-patched-source.tar.xz"

wrong_xz_contract="$temporary_root/wrong-xz-contract.env"
sed 's/^SP11_KERNEL_SOURCE_ARCHIVE_XZ_VERSION=.*/SP11_KERNEL_SOURCE_ARCHIVE_XZ_VERSION="xz (XZ Utils) 0.0.0"/' \
  "$contract" > "$wrong_xz_contract"
expect_failure 'installed XZ version' "$output_a/wrong-xz-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$wrong_xz_contract" \
  --output "$output_a/wrong-xz-patched-source.tar.xz"

wrong_xz_library_contract="$temporary_root/wrong-xz-library-contract.env"
sed 's/^SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_SHA256=.*/SP11_KERNEL_SOURCE_ARCHIVE_XZ_LIBRARY_SHA256="0000000000000000000000000000000000000000000000000000000000000000"/' \
  "$contract" > "$wrong_xz_library_contract"
expect_failure 'installed XZ compression library SHA-256' \
  "$output_a/wrong-xz-library-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$wrong_xz_library_contract" \
  --output "$output_a/wrong-xz-library-patched-source.tar.xz"

wrong_validator_contract="$temporary_root/wrong-validator-contract.env"
sed 's/^SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256=.*/SP11_KERNEL_SOURCE_ARCHIVE_VALIDATOR_SHA256="0000000000000000000000000000000000000000000000000000000000000000"/' \
  "$contract" > "$wrong_validator_contract"
expect_failure 'validator SHA-256' \
  "$output_a/wrong-validator-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$wrong_validator_contract" \
  --output "$output_a/wrong-validator-patched-source.tar.xz"

source_link="$temporary_root/source-link"
ln -s "$source_repo" "$source_link"
expect_failure 'source repository must be a real' "$output_a/source-link-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_link" --toolchain-contract "$contract" \
  --output "$output_a/source-link-patched-source.tar.xz"

real_output_ancestor="$temporary_root/real-output-ancestor"
symlink_output_ancestor="$temporary_root/symlink-output-ancestor"
mkdir -p "$real_output_ancestor/child"
ln -s "$real_output_ancestor" "$symlink_output_ancestor"
expect_failure 'symlinked ancestor' \
  "$symlink_output_ancestor/child/ancestor-patched-source.tar.xz" \
  run_generator --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$symlink_output_ancestor/child/ancestor-patched-source.tar.xz"

# Replace the scratch root name after its inode has been pinned.  The process
# may continue inside the held inode, but must fail before install and must not
# rename, remove, chmod, or otherwise mutate the replacement victim.
scratch_swap_output="$temporary_root/scratch-swap-output"
mkdir "$scratch_swap_output"
scratch_swap_archive="$scratch_swap_output/scratch-swap-patched-source.tar.xz"
GENERATOR_SCRATCH_PARENT="$scratch_swap_output" run_generator \
  --baseline "$baseline" --build-manifest "$manifest" \
  --source-repo "$source_repo" --toolchain-contract "$contract" \
  --output "$scratch_swap_archive" \
  > "$temporary_root/scratch-swap.stdout" \
  2> "$temporary_root/scratch-swap.stderr" &
scratch_swap_pid=$!
scratch_swap_root=""
for ((scratch_attempt = 0; scratch_attempt < 1000; scratch_attempt++)); do
  for scratch_candidate in "$scratch_swap_output"/.sp11-source-archive.*; do
    if [ -d "$scratch_candidate" ] && [ ! -L "$scratch_candidate" ]; then
      scratch_swap_root="$scratch_candidate"
      break 2
    fi
  done
  kill -0 "$scratch_swap_pid" 2>/dev/null || break
  sleep 0.01
done
if [ -z "$scratch_swap_root" ]; then
  wait "$scratch_swap_pid" 2>/dev/null || true
  die "could not observe the pinned scratch root for the swap fixture"
fi
scratch_swap_moved="$scratch_swap_root.creation-owned"
mv "$scratch_swap_root" "$scratch_swap_moved"
mkdir -m 700 "$scratch_swap_root"
scratch_swap_victim="$scratch_swap_root/preserve-victim"
printf 'preserve scratch replacement victim\n' > "$scratch_swap_victim"
scratch_swap_victim_sha="$(shasum -a 256 "$scratch_swap_victim" | awk '{print $1}')"
if wait "$scratch_swap_pid"; then
  die "generator accepted a replaced private scratch root"
fi
grep -Fqi 'private scratch' "$temporary_root/scratch-swap.stderr" ||
  die "scratch-root replacement failure was not explicit"
[ ! -e "$scratch_swap_archive" ] && [ ! -L "$scratch_swap_archive" ] ||
  die "scratch-root replacement installed an archive"
[ "$(shasum -a 256 "$scratch_swap_victim" | awk '{print $1}')" = \
  "$scratch_swap_victim_sha" ] || die "scratch-root replacement victim changed"

victim="$temporary_root/victim"
printf 'preserve victim\n' > "$victim"
victim_sha="$(shasum -a 256 "$victim" | awk '{print $1}')"
existing_output="$output_a/existing-patched-source.tar.xz"
printf 'preserve existing\n' > "$existing_output"
if run_generator --baseline "$baseline" --build-manifest "$manifest" \
    --source-repo "$source_repo" --toolchain-contract "$contract" \
    --output "$existing_output" > "$temporary_root/existing.log" 2>&1; then
  die "generator overwrote an existing output"
fi
grep -Fxq 'preserve existing' "$existing_output" || die "existing output changed"

symlink_output="$output_a/symlink-patched-source.tar.xz"
ln -s "$victim" "$symlink_output"
if run_generator --baseline "$baseline" --build-manifest "$manifest" \
    --source-repo "$source_repo" --toolchain-contract "$contract" \
    --output "$symlink_output" > "$temporary_root/symlink.log" 2>&1; then
  die "generator accepted a symlink output"
fi
[ "$(shasum -a 256 "$victim" | awk '{print $1}')" = "$victim_sha" ] ||
  die "symlink output changed its victim"

fifo_output="$output_a/fifo-patched-source.tar.xz"
mkfifo "$fifo_output"
if run_generator --baseline "$baseline" --build-manifest "$manifest" \
    --source-repo "$source_repo" --toolchain-contract "$contract" \
    --output "$fifo_output" > "$temporary_root/fifo.log" 2>&1; then
  die "generator accepted a FIFO output"
fi
[ -p "$fifo_output" ] || die "FIFO output fixture was changed"

python3 - "$scratch_parent" "$scratch_swap_moved" "$late_scratch_owned" <<'PY_FINAL_SCRUB'
import pathlib
import stat
import sys

roots = list(pathlib.Path(sys.argv[1]).glob(".sp11-source-archive.*"))
roots.append(pathlib.Path(sys.argv[2]))
roots.append(pathlib.Path(sys.argv[3]))
assert roots
for scratch in roots:
    metadata = scratch.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)
    members = list(scratch.rglob("*"))
    assert len(members) <= 32
    for member in members:
        member_metadata = member.lstat()
        assert not stat.S_ISLNK(member_metadata.st_mode)
        assert stat.S_ISDIR(member_metadata.st_mode) or (
            stat.S_ISREG(member_metadata.st_mode) and member_metadata.st_size == 0
        ), (member, oct(member_metadata.st_mode), member_metadata.st_size)
PY_FINAL_SCRUB

printf 'Deterministic kernel source archive generation fixtures passed.\n'
