#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
validator="$repo_dir/scripts/validate-sp11-kernel-tree-symlinks.py"
python_bin=/usr/bin/python3
git_bin=/usr/bin/git
temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-kernel-tree-links.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing unexpected kernel-tree-link fixture cleanup" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

die() {
  echo "kernel-tree-link fixture failed: $*" >&2
  exit 1
}

for tool in cp grep mkfifo mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "missing fixture tool: $tool"
done
[ -x "$python_bin" ] || die "missing fixed Python interpreter: $python_bin"
[ -x "$git_bin" ] || die "missing fixed Git executable: $git_bin"
[ -f "$validator" ] && [ ! -L "$validator" ] || die "missing validator"
grep -Fq 'pass_fds=(EMPTY_CONFIG_FD, SOURCE_OBJECTS_FD)' "$validator" ||
  die "validator does not pass its held empty-config descriptor to Git"
if grep -Eq '/dev/null|subprocess\.DEVNULL' "$validator"; then
  die "validator reintroduced a mutable pathname output/config sink"
fi

temporary_root="$(mktemp -d "$temporary_parent/sp11-kernel-tree-links.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"

git_configure() {
  "$git_bin" -C "$1" config user.name 'SP11 tree-link fixture'
  "$git_bin" -C "$1" config user.email 'sp11-tree-link@example.invalid'
}

run_validator() {
  local repository="$1" tree="$2" log="$3"
  "$python_bin" -I "$validator" \
    --repo "$repository" \
    --tree "$tree" \
    --scratch-parent "$temporary_root" > "$log" 2>&1
}

expect_failure() {
  local label="$1" repository="$2" tree="$3" expected="$4"
  local log="$temporary_root/$label.log"
  if run_validator "$repository" "$tree" "$log"; then
    die "validator accepted $label"
  fi
  grep -Fq "$expected" "$log" || {
    sed -n '1,20p' "$log" >&2
    die "$label did not produce the expected bounded diagnostic"
  }
  if grep -Fq 'Traceback (most recent call last)' "$log"; then
    die "$label leaked a Python traceback"
  fi
}

# A contained tracked link is safe. The validator consumes the exact tree
# object, so changing the live worktree link afterwards cannot change its
# result. An ignored untracked absolute link is likewise outside that tree.
safe_repo="$temporary_root/safe-repo"
mkdir -p "$safe_repo/inside"
"$git_bin" -C "$safe_repo" init --quiet --initial-branch=fixture
git_configure "$safe_repo"
printf 'tracked target\n' > "$safe_repo/inside/target"
printf '/ignored-link\n' > "$safe_repo/.gitignore"
ln -s target "$safe_repo/inside/link"
"$git_bin" -C "$safe_repo" add .
"$git_bin" -C "$safe_repo" commit --quiet -m 'Create safe exact tree'
safe_tree="$("$git_bin" -C "$safe_repo" rev-parse 'HEAD^{tree}')"
run_validator "$safe_repo" "$safe_tree" "$temporary_root/safe.log" || {
  sed -n '1,20p' "$temporary_root/safe.log" >&2
  die "validator rejected a contained exact-tree link"
}
grep -Fq '1 symlinks.' "$temporary_root/safe.log" ||
  die "safe-tree result did not report its symlink count"

# An inherited ignored SIGCHLD must not auto-reap Git children behind the
# validator's exact owner.  The CLI resets it to the waitable default before
# its first spawn and completes the same exact-tree validation.
if ! "$python_bin" -I -c '
import os
import signal
import sys

signal.signal(signal.SIGCHLD, signal.SIG_IGN)
os.execv(sys.argv[1], sys.argv[1:])
' "$python_bin" -I "$validator" \
    --repo "$safe_repo" --tree "$safe_tree" \
    --scratch-parent "$temporary_root" \
    > "$temporary_root/sigchld-ignored.log" 2>&1; then
  sed -n '1,20p' "$temporary_root/sigchld-ignored.log" >&2
  die "validator did not establish a waitable child contract"
fi
grep -Fq 'Validated exact kernel tree symlink containment:' \
  "$temporary_root/sigchld-ignored.log" ||
  die "SIGCHLD contract fixture omitted exact-tree success"

# Exercise both asynchronous child-ownership fences without depending on Git
# timing.  The terminal-wait wrapper reaps with raw waitpid(), queues SIGINT
# before recording Popen.returncode, and proves the pending handler runs only
# after the live-owner entry is removed.  Separate HUP/TERM cases queue the
# signal inside Popen after child creation but before it returns; each child
# must already be registered when the handler runs and must then be reaped.
if ! "$python_bin" -I -c '
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys

validator_path = Path(sys.argv[1])
private_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "sp11_tree_child_owner_fixture", validator_path
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.install_release_signal_contract()
module.establish_child_reaping_contract()
module.verify_private_git_view = lambda: None

kill_marker = private_path / "reaped-child-kill"
process = subprocess.Popen(
    [sys.executable, "-I", "-c", "pass"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
module.LIVE_PROCESSES.add(process)

def raw_wait_with_pending_signal():
    waited, status = os.waitpid(process.pid, 0)
    assert waited == process.pid
    os.kill(os.getpid(), signal.SIGINT)
    process.returncode = os.waitstatus_to_exitcode(status)
    return process.returncode

process.wait = raw_wait_with_pending_signal
process.kill = lambda: kill_marker.write_text("unsafe kill\n", encoding="ascii")
try:
    module.reap_registered(process)
except KeyboardInterrupt:
    pass
else:
    raise AssertionError("pending terminal-wait signal was not delivered")
assert process.returncode == 0
assert process not in module.LIVE_PROCESSES
assert not kill_marker.exists()
signal.pthread_sigmask(signal.SIG_SETMASK, set())

private_fd = os.open(private_path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
config_read, config_write = os.pipe()
os.close(config_write)
module.PRIVATE_ROOT_FD = private_fd
module.EMPTY_CONFIG_FD = config_read
module.SOURCE_OBJECTS_FD = os.dup(private_fd)
module.SOURCE_OBJECTS_PATH = str(private_path)
module.SOURCE_REPO = str(private_path)
original_popen = module.subprocess.Popen
registration_child = None
try:
    for signum in (signal.SIGHUP, signal.SIGTERM):
        captured = []

        def pending_popen(*arguments, **keywords):
            child = original_popen(*arguments, **keywords)
            captured.append(child)
            os.kill(os.getpid(), signum)
            return child

        module.subprocess.Popen = pending_popen
        try:
            module.spawn_registered(
                [sys.executable, "-I", "-c", "import time; time.sleep(30)"],
                repo=str(private_path),
            )
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("pending acquisition signal was not delivered")
        assert len(captured) == 1
        child = captured[0]
        assert child in module.LIVE_PROCESSES
        signal.pthread_sigmask(signal.SIG_SETMASK, set())
        module.kill_all_registered()
        assert child not in module.LIVE_PROCESSES
        assert child.returncode is not None

    class RejectingOwnerSet(set):
        def add(self, _process):
            raise MemoryError("fixture registration refusal")

    captured_registration = []

    def registration_popen(*arguments, **keywords):
        child = original_popen(*arguments, **keywords)
        captured_registration.append(child)
        return child

    module.subprocess.Popen = registration_popen
    module.LIVE_PROCESSES = RejectingOwnerSet()
    try:
        module.spawn_registered(
            [sys.executable, "-I", "-c", "import time; time.sleep(30)"],
            repo=str(private_path),
        )
    except MemoryError:
        pass
    else:
        raise AssertionError("child owner accepted a rejecting registration set")
    assert len(captured_registration) == 1
    registration_child = captured_registration[0]
    assert registration_child.returncode is not None
    try:
        os.waitpid(registration_child.pid, os.WNOHANG)
    except ChildProcessError:
        pass
    else:
        raise AssertionError("registration-failure child was not exactly reaped")
    module.LIVE_PROCESSES = set()
finally:
    module.subprocess.Popen = original_popen
    signal.pthread_sigmask(signal.SIG_BLOCK, module.RELEASE_SIGNALS)
    if registration_child is not None and registration_child.returncode is None:
        try:
            registration_child.kill()
        except OSError:
            pass
        try:
            registration_child.wait()
        except OSError:
            pass
    if not isinstance(module.LIVE_PROCESSES, set):
        module.LIVE_PROCESSES = set()
    module.kill_all_registered()
    for descriptor in (
        module.SOURCE_OBJECTS_FD,
        module.EMPTY_CONFIG_FD,
        module.PRIVATE_ROOT_FD,
    ):
        if descriptor >= 0:
            os.close(descriptor)
print("exact-tree child ownership fixtures passed")
' "$validator" "$temporary_root" \
    > "$temporary_root/child-owner.log" 2>&1; then
  sed -n '1,40p' "$temporary_root/child-owner.log" >&2
  die "exact-tree child ownership fixture failed"
fi
grep -Fq 'exact-tree child ownership fixtures passed' \
  "$temporary_root/child-owner.log" ||
  die "exact-tree child ownership fixture omitted its completion marker"

# The object reader uses its own pinned bare view. A source-local include FIFO
# therefore cannot become configuration authority or block Git startup.
cp "$safe_repo/.git/config" "$temporary_root/safe-repo.config"
hostile_include="$temporary_root/hostile-local-config.fifo"
mkfifo "$hostile_include"
printf '\n[include]\n\tpath = %s\n' "$hostile_include" >> "$safe_repo/.git/config"
if ! "$python_bin" -I -c '
import subprocess
import sys

with open(sys.argv[1], "wb") as output:
    subprocess.run(
        sys.argv[2:],
        stdout=output,
        stderr=subprocess.STDOUT,
        timeout=5,
        check=True,
    )
' "$temporary_root/hostile-local-config.log" \
    "$python_bin" -I "$validator" --repo "$safe_repo" --tree "$safe_tree" \
    --scratch-parent "$temporary_root"; then
  cp "$temporary_root/safe-repo.config" "$safe_repo/.git/config"
  sed -n '1,20p' "$temporary_root/hostile-local-config.log" >&2
  die "source-local include authority influenced the private Git view"
fi
cp "$temporary_root/safe-repo.config" "$safe_repo/.git/config"

rm "$safe_repo/inside/link"
ln -s /private/host-only/replacement "$safe_repo/inside/link"
ln -s /private/ignored-host-link "$safe_repo/ignored-link"
run_validator "$safe_repo" "$safe_tree" "$temporary_root/worktree-swap.log" || {
  sed -n '1,20p' "$temporary_root/worktree-swap.log" >&2
  die "live worktree state influenced the captured exact tree"
}

# This mirrors the real failure and intended repair: an unsafe link can exist
# in the source commit, but a patched tree which deletes it is safe. No live
# target is followed or copied.
deletion_repo="$temporary_root/deletion-repo"
mkdir -p "$deletion_repo/debian/scripts/misc"
"$git_bin" -C "$deletion_repo" init --quiet --initial-branch=fixture
git_configure "$deletion_repo"
absolute_target='/private/host-only/stubble/hwids/finddtbs.py'
ln -s "$absolute_target" "$deletion_repo/debian/scripts/misc/find-dtbs.py"
printf 'fixture\n' > "$deletion_repo/README"
"$git_bin" -C "$deletion_repo" add .
"$git_bin" -C "$deletion_repo" commit --quiet -m 'Create unsafe baseline tree'
unsafe_tree="$("$git_bin" -C "$deletion_repo" rev-parse 'HEAD^{tree}')"
expect_failure absolute "$deletion_repo" "$unsafe_tree" \
  "exact tree symbolic link has an absolute target: 'debian/scripts/misc/find-dtbs.py'"
if grep -Fq "$absolute_target" "$temporary_root/absolute.log"; then
  die "absolute-target diagnostic leaked target bytes"
fi

"$git_bin" -C "$deletion_repo" rm --quiet debian/scripts/misc/find-dtbs.py
deleted_tree="$("$git_bin" -C "$deletion_repo" write-tree)"
run_validator "$deletion_repo" "$deleted_tree" "$temporary_root/deleted.log" || {
  sed -n '1,20p' "$temporary_root/deleted.log" >&2
  die "validator rejected a patched tree that deleted the unsafe link"
}
grep -Fq '0 symlinks.' "$temporary_root/deleted.log" ||
  die "deleted-link tree retained a symlink"

# Restoring the worktree to a benign link cannot sanitize the already captured
# unsafe tree object.
"$git_bin" -C "$deletion_repo" reset --hard --quiet HEAD
rm "$deletion_repo/debian/scripts/misc/find-dtbs.py"
ln -s ../../../README "$deletion_repo/debian/scripts/misc/find-dtbs.py"
expect_failure captured-unsafe "$deletion_repo" "$unsafe_tree" \
  "exact tree symbolic link has an absolute target"

# Relative root escape, backslash, and control-byte targets are rejected. The
# diagnostic names only the safely escaped member path, never target bytes.
rm "$deletion_repo/debian/scripts/misc/find-dtbs.py"
ln -s ../../../../outside "$deletion_repo/debian/scripts/misc/find-dtbs.py"
"$git_bin" -C "$deletion_repo" add debian/scripts/misc/find-dtbs.py
relative_escape_tree="$("$git_bin" -C "$deletion_repo" write-tree)"
expect_failure relative-escape "$deletion_repo" "$relative_escape_tree" \
  "exact tree symbolic link escapes the tree root"

# Containment is compositional, not merely lexical. Expanding the tracked
# root-level link in x/s makes the following .. leave the exact tree, even
# though each target passes an isolated lexical normalization.
chain_escape_repo="$temporary_root/chain-escape-repo"
mkdir -p "$chain_escape_repo/x"
"$git_bin" -C "$chain_escape_repo" init --quiet --initial-branch=fixture
git_configure "$chain_escape_repo"
ln -s . "$chain_escape_repo/a"
ln -s ../a/../outside "$chain_escape_repo/x/s"
"$git_bin" -C "$chain_escape_repo" add .
chain_escape_tree="$("$git_bin" -C "$chain_escape_repo" write-tree)"
expect_failure composed-escape "$chain_escape_repo" "$chain_escape_tree" \
  "exact tree symbolic link escapes the tree root: 'x/s'"

# Safe tracked-link composition and a contained dangling target remain valid.
safe_chain_repo="$temporary_root/safe-chain-repo"
mkdir -p "$safe_chain_repo/dir"
"$git_bin" -C "$safe_chain_repo" init --quiet --initial-branch=fixture
git_configure "$safe_chain_repo"
printf 'safe chain target\n' > "$safe_chain_repo/dir/target"
ln -s dir "$safe_chain_repo/a"
ln -s a/target "$safe_chain_repo/b"
ln -s missing/child "$safe_chain_repo/dangling"
ln -s a/../a/target "$safe_chain_repo/repeated"
"$git_bin" -C "$safe_chain_repo" add .
safe_chain_tree="$("$git_bin" -C "$safe_chain_repo" write-tree)"
run_validator "$safe_chain_repo" "$safe_chain_tree" \
  "$temporary_root/safe-chain.log" || {
    sed -n '1,20p' "$temporary_root/safe-chain.log" >&2
    die "validator rejected safe tracked-link composition"
  }
grep -Fq '4 symlinks.' "$temporary_root/safe-chain.log" ||
  die "safe-chain result did not report every symlink"

# Cycles fail explicitly, and the expansion bound accepts its exact limit but
# rejects the next acyclic chain without unbounded work.
cycle_repo="$temporary_root/cycle-repo"
mkdir "$cycle_repo"
"$git_bin" -C "$cycle_repo" init --quiet --initial-branch=fixture
git_configure "$cycle_repo"
ln -s b "$cycle_repo/a"
ln -s a "$cycle_repo/b"
"$git_bin" -C "$cycle_repo" add .
cycle_tree="$("$git_bin" -C "$cycle_repo" write-tree)"
expect_failure cycle "$cycle_repo" "$cycle_tree" \
  'exact tree symbolic-link resolution contains a cycle'

limit_chain_repo="$temporary_root/limit-chain-repo"
mkdir "$limit_chain_repo"
"$git_bin" -C "$limit_chain_repo" init --quiet --initial-branch=fixture
git_configure "$limit_chain_repo"
printf 'limit target\n' > "$limit_chain_repo/target"
for ((index = 0; index <= 256; index++)); do
  next=$((index + 1))
  if [ "$index" -eq 256 ]; then
    destination=target
  else
    destination="link-$(printf '%03d' "$next")"
  fi
  ln -s "$destination" "$limit_chain_repo/link-$(printf '%03d' "$index")"
done
"$git_bin" -C "$limit_chain_repo" add .
limit_chain_tree="$("$git_bin" -C "$limit_chain_repo" write-tree)"
run_validator "$limit_chain_repo" "$limit_chain_tree" \
  "$temporary_root/limit-chain.log" || {
    sed -n '1,20p' "$temporary_root/limit-chain.log" >&2
    die "validator rejected the exact symbolic-link expansion limit"
  }
ln -s link-000 "$limit_chain_repo/over-limit"
"$git_bin" -C "$limit_chain_repo" add over-limit
over_limit_chain_tree="$("$git_bin" -C "$limit_chain_repo" write-tree)"
expect_failure over-limit-chain "$limit_chain_repo" "$over_limit_chain_tree" \
  'exact tree symbolic-link resolution exceeded its expansion bound'

# A repeated near-limit target made mostly of no-op components consumes the
# shared raw-plus-composed step budget linearly: neither pass alone reaches the
# limit. This fixture would also amplify a per-step full-queue rescan into
# quadratic work.
many_dot_blob="$(
  "$python_bin" -I -c 'import sys; sys.stdout.buffer.write(b"./" * 2047 + b"x")' |
    "$git_bin" -C "$limit_chain_repo" hash-object -w --stdin
)"
many_dot_tree="$(
  "$python_bin" -I -c '
import sys
oid = sys.argv[1]
for index in range(300):
    sys.stdout.write(f"120000 blob {oid}\twork-{index:03d}\0")
' "$many_dot_blob" | "$git_bin" -C "$limit_chain_repo" mktree -z
)"
expect_failure many-dot-work "$limit_chain_repo" "$many_dot_tree" \
  'exact tree symbolic-link resolution exceeded its aggregate work bound'

rm "$deletion_repo/debian/scripts/misc/find-dtbs.py"
ln -s 'hidden\target' "$deletion_repo/debian/scripts/misc/find-dtbs.py"
"$git_bin" -C "$deletion_repo" add debian/scripts/misc/find-dtbs.py
backslash_tree="$("$git_bin" -C "$deletion_repo" write-tree)"
expect_failure backslash "$deletion_repo" "$backslash_tree" \
  "exact tree symbolic link has an unsafe target"
if grep -Fq 'hidden' "$temporary_root/backslash.log"; then
  die "backslash-target diagnostic leaked target bytes"
fi

rm "$deletion_repo/debian/scripts/misc/find-dtbs.py"
ln -s $'hidden\nterminal-injection' "$deletion_repo/debian/scripts/misc/find-dtbs.py"
"$git_bin" -C "$deletion_repo" add debian/scripts/misc/find-dtbs.py
control_target_tree="$("$git_bin" -C "$deletion_repo" write-tree)"
expect_failure control-target "$deletion_repo" "$control_target_tree" \
  "exact tree symbolic link has an unsafe target"
if grep -Fq 'terminal-injection' "$temporary_root/control-target.log"; then
  die "control-target diagnostic leaked target bytes"
fi

# A control byte in a member path is rendered as an escape on one diagnostic
# line, preventing terminal injection.
control_path_repo="$temporary_root/control-path-repo"
mkdir "$control_path_repo"
"$git_bin" -C "$control_path_repo" init --quiet --initial-branch=fixture
git_configure "$control_path_repo"
printf 'target\n' > "$control_path_repo/target"
ln -s target "$control_path_repo/"$'member\nforged-error'
"$git_bin" -C "$control_path_repo" add .
control_path_tree="$("$git_bin" -C "$control_path_repo" write-tree)"
expect_failure control-path "$control_path_repo" "$control_path_tree" \
  "control byte in member path 'member\\x0aforged-error'"
[ "$(wc -l < "$temporary_root/control-path.log" | tr -d ' ')" -eq 1 ] ||
  die "control-path diagnostic injected an extra line"

# Object plumbing covers targets the host filesystem cannot materialize: an
# empty target, an oversized target, and a referenced-but-missing blob.
object_repo="$temporary_root/object-repo"
mkdir "$object_repo"
"$git_bin" -C "$object_repo" init --quiet --initial-branch=fixture
git_configure "$object_repo"
empty_blob="$(printf '' | "$git_bin" -C "$object_repo" hash-object -w --stdin)"
empty_tree="$(printf '120000 blob %s\tempty-link\0' "$empty_blob" | \
  "$git_bin" -C "$object_repo" mktree -z)"
expect_failure empty-target "$object_repo" "$empty_tree" \
  "exact tree symbolic link has an empty target"

oversized_blob="$("$python_bin" -I -c 'import sys; sys.stdout.write("x" * 4097)' | \
  "$git_bin" -C "$object_repo" hash-object -w --stdin)"
oversized_tree="$(printf '120000 blob %s\toversized-link\0' "$oversized_blob" | \
  "$git_bin" -C "$object_repo" mktree -z)"
expect_failure oversized-target "$object_repo" "$oversized_tree" \
  "Git object exceeded the validation size bound for tree member 'oversized-link'"

missing_blob=1111111111111111111111111111111111111111
missing_tree="$(printf '120000 blob %s\tmissing-link\0' "$missing_blob" | \
  "$git_bin" -C "$object_repo" mktree -z --missing)"
expect_failure missing-object "$object_repo" "$missing_tree" \
  "Git object reader returned malformed metadata for tree member 'missing-link'"

expect_failure missing-tree "$object_repo" 2222222222222222222222222222222222222222 \
  'Git failed while resolving the exact tree'

# Every nested tree object is read with a prior size check and independently
# rehashed. Replacing a nested loose object under the OID named by its parent
# therefore cannot hide a hostile link from the recursive parser.
nested_repo="$temporary_root/nested-repo"
mkdir -p "$nested_repo/safe"
"$git_bin" -C "$nested_repo" init --quiet --initial-branch=fixture
git_configure "$nested_repo"
printf 'nested target\n' > "$nested_repo/safe/target"
ln -s target "$nested_repo/safe/link"
"$git_bin" -C "$nested_repo" add .
"$git_bin" -C "$nested_repo" commit --quiet -m 'Create nested safe tree'
nested_root="$("$git_bin" -C "$nested_repo" rev-parse 'HEAD^{tree}')"
nested_safe="$("$git_bin" -C "$nested_repo" rev-parse 'HEAD:safe')"
nested_hostile_blob="$(printf '/private/host-only/nested-secret' | \
  "$git_bin" -C "$nested_repo" hash-object -w --stdin)"
nested_hostile_tree="$(printf '120000 blob %s\thostile-link\0' "$nested_hostile_blob" | \
  "$git_bin" -C "$nested_repo" mktree -z)"
nested_safe_object="$nested_repo/.git/objects/${nested_safe:0:2}/${nested_safe:2}"
nested_hostile_object="$nested_repo/.git/objects/${nested_hostile_tree:0:2}/${nested_hostile_tree:2}"
[ -f "$nested_safe_object" ] && [ -f "$nested_hostile_object" ] ||
  die "nested substitution fixture did not retain loose tree objects"
chmod u+w "$nested_safe_object"
cp "$nested_hostile_object" "$nested_safe_object"
expect_failure nested-substitution "$nested_repo" "$nested_root" \
  "Git object bytes did not match their exact object ID for tree member 'safe'"
if grep -Fq '/private/host-only/nested-secret' \
    "$temporary_root/nested-substitution.log"; then
  die "nested-substitution diagnostic leaked hostile target bytes"
fi

# An oversized nested tree is rejected from bounded batch-check metadata before
# the content reader is asked to materialize it.
oversized_tree_repo="$temporary_root/oversized-tree-repo"
mkdir "$oversized_tree_repo"
"$git_bin" -C "$oversized_tree_repo" init --quiet --initial-branch=fixture
git_configure "$oversized_tree_repo"
regular_blob="$(printf 'x' | "$git_bin" -C "$oversized_tree_repo" hash-object -w --stdin)"
oversized_nested_tree="$(
  "$python_bin" -I -c '
import sys
oid = bytes.fromhex(sys.argv[1])
output = sys.stdout.buffer
for index in range(110000):
    output.write(b"100644 entry-" + f"{index:06d}".encode() + b"\0" + oid)
' "$regular_blob" | "$git_bin" -C "$oversized_tree_repo" \
    hash-object -t tree -w --stdin
)"
oversized_root_tree="$(printf '040000 tree %s\toversized\0' "$oversized_nested_tree" | \
  "$git_bin" -C "$oversized_tree_repo" mktree -z)"
expect_failure oversized-nested-tree "$oversized_tree_repo" "$oversized_root_tree" \
  "Git object exceeded the validation size bound for tree member 'oversized'"

# Path depth is bounded independently of total path bytes.
deep_repo="$temporary_root/deep-repo"
mkdir "$deep_repo"
"$git_bin" -C "$deep_repo" init --quiet --initial-branch=fixture
git_configure "$deep_repo"
deep_path="$deep_repo"
depth=0
while [ "$depth" -lt 65 ]; do
  deep_path="$deep_path/d"
  mkdir "$deep_path"
  depth=$((depth + 1))
done
printf 'deep\n' > "$deep_path/file"
"$git_bin" -C "$deep_repo" add .
deep_tree="$("$git_bin" -C "$deep_repo" write-tree)"
expect_failure deep-path "$deep_repo" "$deep_tree" \
  'exact tree member path exceeds the depth bound'

# The same exact-object contract works for SHA-256 repositories when the fixed
# Git implementation supports them.
sha256_repo="$temporary_root/sha256-repo"
mkdir "$sha256_repo"
if "$git_bin" -C "$sha256_repo" init --quiet --initial-branch=fixture \
    --object-format=sha256 2>/dev/null; then
  git_configure "$sha256_repo"
  mkdir "$sha256_repo/inside"
  printf 'sha256 target\n' > "$sha256_repo/inside/target"
  ln -s target "$sha256_repo/inside/link"
  "$git_bin" -C "$sha256_repo" add .
  sha256_tree="$("$git_bin" -C "$sha256_repo" write-tree)"
  run_validator "$sha256_repo" "$sha256_tree" "$temporary_root/sha256.log" || {
    sed -n '1,20p' "$temporary_root/sha256.log" >&2
    die "validator rejected a safe SHA-256 exact tree"
  }
fi

# Deleted-path framing is consumed with linear cursor/compaction work. A high
# count of short absent paths must complete within a bounded fixture timeout;
# the former per-entry front deletion shifted the remaining chunk repeatedly.
if ! "$python_bin" -I -c '
import subprocess
import sys

payload = b"absent-deleted-path\0" * 100000
completed = subprocess.run(
    [
        sys.argv[1],
        "-I",
        sys.argv[2],
        "--check-deleted-paths",
        sys.argv[3],
        "--max-input-bytes",
        str(len(payload)),
    ],
    input=payload,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=10,
    check=False,
)
if completed.returncode != 0 or completed.stdout or completed.stderr:
    raise SystemExit(1)
' "$python_bin" "$validator" "$safe_repo"; then
  die "high-count deleted-path stream exceeded its linear work bound"
fi
if printf 'unterminated-deleted-path' | "$python_bin" -I "$validator" \
    --check-deleted-paths "$safe_repo" --max-input-bytes 4096 \
    > "$temporary_root/deleted-path-framing.log" 2>&1; then
  die "deleted-path utility accepted unterminated framing"
fi
grep -Fq 'deleted-path stream ended without NUL framing' \
  "$temporary_root/deleted-path-framing.log" ||
  die "deleted-path framing failure was not explicit"

# Isolated startup is part of the public CLI contract.
if "$python_bin" "$validator" --repo "$safe_repo" --tree "$safe_tree" \
    > "$temporary_root/non-isolated.log" 2>&1; then
  die "validator accepted non-isolated Python startup"
fi
grep -Fq 'must be started with Python isolated mode (-I)' \
  "$temporary_root/non-isolated.log" ||
  die "non-isolated startup failure was not explicit"

echo 'Exact kernel-tree symlink safety fixtures passed.'
