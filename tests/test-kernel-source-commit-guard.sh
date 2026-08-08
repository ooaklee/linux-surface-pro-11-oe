#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""
root_parent_work=""
root_parent_created="false"
root_parent_identity=""

directory_identity() {
	local path="$1" identity=""

	[ -d "$path" ] && [ ! -L "$path" ] || return 1
	if identity="$(stat -c '%d:%i' -- "$path" 2>/dev/null)"; then
		printf '%s\n' "$identity"
	elif identity="$(stat -f '%d:%i' "$path" 2>/dev/null)"; then
		printf '%s\n' "$identity"
	else
		return 1
	fi
}

cleanup() {
	local current_identity=""

	if [ "$root_parent_created" = "true" ] && [ -n "$root_parent_work" ]; then
		case "$root_parent_work" in
			/sp11-source-guard-root-*)
				current_identity="$(directory_identity "$root_parent_work" || true)"
				if [ "$(id -u)" -eq 0 ] && [ -n "$root_parent_identity" ] &&
				   [ "$current_identity" = "$root_parent_identity" ]; then
					rm -rf -- "$root_parent_work"
				else
					echo "warning: refusing to remove changed direct-root test path: $root_parent_work" >&2
				fi
				;;
			*)
				echo "warning: refusing to remove unexpected direct-root test path: $root_parent_work" >&2
				;;
		esac
	fi
	[ -n "$temporary_root" ] || return 0
	case "$temporary_root" in
		"$temporary_parent"/sp11-source-guard.*)
			rm -rf -- "$temporary_root"
			;;
		*)
			echo "warning: refusing to remove unexpected temporary path: $temporary_root" >&2
			;;
	esac
}
trap cleanup EXIT

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

for tool in cmp git grep mktemp stat; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root="$(mktemp -d "$temporary_parent/sp11-source-guard.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
fixture_repo="$temporary_root/source-repository"
alternate_repo="$temporary_root/alternate-source.git"
patch_dir="$temporary_root/patches"
work_dir="$temporary_root/work"
output_file="$temporary_root/output"
mkdir -p "$fixture_repo" "$patch_dir"

git -C "$fixture_repo" init --quiet --initial-branch=fixture
git -C "$fixture_repo" config user.name "SP11 CI fixture"
git -C "$fixture_repo" config user.email "sp11-ci@example.invalid"
printf 'before\n' > "$fixture_repo/guard.txt"
git -C "$fixture_repo" add guard.txt
git -C "$fixture_repo" commit --quiet -m "Create source-guard fixture"
actual_commit="$(git -C "$fixture_repo" rev-parse --verify 'HEAD^{commit}')"
unexpected_commit="0000000000000000000000000000000000000000"

printf '%s\n' \
	'diff --git a/guard.txt b/guard.txt' \
	'--- a/guard.txt' \
	'+++ b/guard.txt' \
	'@@ -1 +1 @@' \
	'-before' \
	'+after' > "$patch_dir/0001-change-guard-marker.patch"

run_path_guard() {
	local candidate_work="$1"
	local expected_commit="${2:-$actual_commit}"
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
		--source git \
		--git-url "$fixture_repo" \
		--git-branch fixture \
		--expected-source-commit "$expected_commit" \
		--patch-dir "$patch_dir" \
		--work-dir "$candidate_work" \
		--prepare-only
}

# The Docker wrapper mounts its named Linux volume directly at /linux-work.
# Exercise the same direct-root parent when already running as root; otherwise
# retain exact lexical and production-contract regressions for Bash 3 hosts.
root_parent="/"
for root_leaf in linux-work work; do
	if [ "$root_parent" = "/" ]; then
		root_join="/$root_leaf"
	else
		root_join="$root_parent/$root_leaf"
	fi
	[ "$root_join" = "/$root_leaf" ] || die "direct-root work path was not canonical: /$root_leaf"
	[ "$root_join" != "$root_parent/$root_leaf" ] ||
		die "direct-root regression did not distinguish /$root_leaf from //$root_leaf"
done
grep -Fq 'if [ "$work_parent_physical" = "/" ]; then' \
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
	die "kernel builder does not distinguish the filesystem root from other parents"
grep -Fq 'expected_work_dir="/$work_leaf"' \
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
	die "kernel builder does not form a canonical direct-root work child"
grep -Fq 'expected_work_dir="$work_parent_physical/$work_leaf"' \
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
	die "kernel builder changed nested-parent work-child formation"
grep -Fq 'mkdir "$expected_work_dir"' "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
	die "kernel builder does not create the exact expected work child"
grep -Fq '[ "$work_dir" != "$expected_work_dir" ]' \
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" ||
	die "kernel builder does not compare against the exact expected work child"

can_run_direct_root="false"
if [ "$(id -u)" -eq 0 ]; then
	can_run_direct_root="true"
fi
if [ "$can_run_direct_root" = "true" ]; then
	root_candidate="/sp11-source-guard-root-${temporary_root##*.}"
	if ! mkdir "$root_candidate"; then
		die "could not create private direct-root test path: $root_candidate"
	fi
	root_candidate_identity="$(directory_identity "$root_candidate" || true)"
	if [ -z "$root_candidate_identity" ]; then
		rmdir "$root_candidate"
		die "could not capture private direct-root test identity: $root_candidate"
	fi
	root_parent_work="$root_candidate"
	root_parent_identity="$root_candidate_identity"
	root_parent_created="true"
	if run_path_guard "$root_parent_work" "$unexpected_commit" \
		> "$temporary_root/direct-root.log" 2>&1; then
		cat "$temporary_root/direct-root.log" >&2
		die "direct-root probe accepted an unexpected source commit"
	fi
	[ -d "$root_parent_work" ] && [ ! -L "$root_parent_work" ] ||
		die "direct-root work directory was not retained as a real directory: $root_parent_work"
	root_cloned_source="$root_parent_work/source/git-fixture"
	[ -d "$root_cloned_source/.git" ] && [ ! -L "$root_cloned_source" ] &&
		[ ! -L "$root_cloned_source/.git" ] || {
		cat "$temporary_root/direct-root.log" >&2
		die "direct-root probe did not retain a real cloned checkout"
	}
	grep -Fq 'Resolved kernel source does not match --expected-source-commit.' \
		"$temporary_root/direct-root.log" || {
		cat "$temporary_root/direct-root.log" >&2
		die "direct-root probe did not reach the source-commit guard"
	}
	grep -Fq 'Refusing to apply patches or start a build from an unexpected source commit.' \
		"$temporary_root/direct-root.log" || {
		cat "$temporary_root/direct-root.log" >&2
		die "direct-root probe did not report its fail-closed boundary"
	}
	if grep -Fq 'Kernel work directory resolves outside its requested managed path' \
		"$temporary_root/direct-root.log"; then
		cat "$temporary_root/direct-root.log" >&2
		die "direct-root probe failed work-directory admission"
	fi
	[ "$(git -C "$root_cloned_source" rev-parse --verify 'HEAD^{commit}')" = "$actual_commit" ] ||
		die "direct-root probe cloned an unexpected source commit"
	git -C "$root_cloned_source" diff --quiet ||
		die "direct-root source-commit guard allowed a worktree mutation"
	git -C "$root_cloned_source" diff --cached --quiet ||
		die "direct-root source-commit guard allowed an index mutation"
	[ -z "$(git -C "$root_cloned_source" ls-files --others --exclude-standard)" ] ||
		die "direct-root source-commit guard allowed an untracked mutation"
	grep -Fxq 'before' "$root_cloned_source/guard.txt" ||
		die "direct-root source-commit guard allowed the fixture patch"
	[ ! -e "$root_parent_work/sp11-kernel-build-manifest.txt" ] ||
		die "direct-root source-commit guard allowed manifest creation"
	if grep -Fq 'Applying patches from' "$temporary_root/direct-root.log"; then
		die "direct-root source-commit guard reached patch application"
	fi
	[ "$(directory_identity "$root_parent_work" || true)" = "$root_parent_identity" ] ||
		die "direct-root work directory identity changed during prepare-only"
	rm -rf -- "$root_parent_work"
	root_parent_work=""
	root_parent_created="false"
	root_parent_identity=""
fi

path_victim="$temporary_root/work-path-victim"
mkdir "$path_victim"
printf 'work path victim must remain unchanged\n' > "$path_victim/sentinel"

if run_path_guard / > "$temporary_root/root-work.log" 2>&1; then
	die "kernel build accepted the filesystem root as its work directory"
fi
grep -Fq 'must use a dedicated canonical path' "$temporary_root/root-work.log" ||
	die "filesystem-root work rejection was not explicit"

for duplicate_root_work in //linux-work //work; do
	duplicate_root_leaf="${duplicate_root_work##*/}"
	if run_path_guard "$duplicate_root_work" \
		> "$temporary_root/duplicate-root-$duplicate_root_leaf.log" 2>&1; then
		die "kernel build accepted a duplicate-separator root child: $duplicate_root_work"
	fi
	grep -Fq 'must use a dedicated canonical path' \
		"$temporary_root/duplicate-root-$duplicate_root_leaf.log" ||
		die "duplicate-separator root-child rejection was not explicit: $duplicate_root_work"
done

if run_path_guard "$temporary_root/safe/../work-path-victim" \
	> "$temporary_root/traversal-work.log" 2>&1; then
	die "kernel build accepted parent traversal in its work directory"
fi
grep -Fq 'must use a dedicated canonical path' "$temporary_root/traversal-work.log" ||
	die "work-directory traversal rejection was not explicit"
grep -Fxq 'work path victim must remain unchanged' "$path_victim/sentinel" ||
	die "work-directory traversal changed its victim"

linked_work="$temporary_root/linked-work"
ln -s "$path_victim" "$linked_work"
if run_path_guard "$linked_work" > "$temporary_root/linked-work.log" 2>&1; then
	die "kernel build accepted a symlink as its work directory"
fi
grep -Fq 'must be a real, non-symlinked directory' "$temporary_root/linked-work.log" ||
	die "symlinked work-directory rejection was not explicit"
grep -Fxq 'work path victim must remain unchanged' "$path_victim/sentinel" ||
	die "symlinked work directory changed its victim"

regular_work="$temporary_root/regular-work"
printf 'regular work path must remain unchanged\n' > "$regular_work"
if run_path_guard "$regular_work" > "$temporary_root/regular-work.log" 2>&1; then
	die "kernel build accepted a regular file as its work directory"
fi
grep -Fq 'must be a real, non-symlinked directory' "$temporary_root/regular-work.log" ||
	die "regular-file work-directory rejection was not explicit"
grep -Fxq 'regular work path must remain unchanged' "$regular_work" ||
	die "regular-file work-directory rejection changed its victim"

victim_repo="$temporary_root/source-symlink-victim"
symlink_work="$temporary_root/symlink-work"
git clone --quiet "$fixture_repo" "$victim_repo"
printf 'locally modified victim\n' > "$victim_repo/guard.txt"
printf 'untracked victim marker\n' > "$victim_repo/untracked-marker.txt"
cp "$victim_repo/guard.txt" "$temporary_root/victim-guard.before"
cp "$victim_repo/untracked-marker.txt" "$temporary_root/victim-untracked.before"
victim_status_before="$(git -C "$victim_repo" status --porcelain --untracked-files=all)"
mkdir -p "$symlink_work/source"
ln -s "$victim_repo" "$symlink_work/source/git-fixture"
run_symlink_source_guard() {
	"$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
		--source git \
		--git-url "$fixture_repo" \
		--git-branch fixture \
		--expected-source-commit "$actual_commit" \
		--patch-dir "$patch_dir" \
		--work-dir "$symlink_work" \
		--prepare-only \
		"$@"
}
for reset_mode in preserve reset; do
	if [ "$reset_mode" = reset ]; then
		if run_symlink_source_guard --reset-source \
			> "$temporary_root/symlink-$reset_mode.log" 2>&1; then
			die "kernel build accepted a symlinked managed checkout in $reset_mode mode"
		fi
	elif run_symlink_source_guard \
		> "$temporary_root/symlink-$reset_mode.log" 2>&1; then
		die "kernel build accepted a symlinked managed checkout in $reset_mode mode"
	fi
	grep -Fq 'must be a real, non-symlinked managed directory' \
		"$temporary_root/symlink-$reset_mode.log" || {
		cat "$temporary_root/symlink-$reset_mode.log" >&2
		die "symlinked checkout rejection was not explicit in $reset_mode mode"
	}
	[ "$(readlink "$symlink_work/source/git-fixture")" = "$victim_repo" ] ||
		die "kernel build changed the managed-checkout symlink in $reset_mode mode"
	cmp "$temporary_root/victim-guard.before" "$victim_repo/guard.txt" ||
		die "kernel build changed tracked victim bytes in $reset_mode mode"
	cmp "$temporary_root/victim-untracked.before" "$victim_repo/untracked-marker.txt" ||
		die "kernel build changed untracked victim bytes in $reset_mode mode"
	[ "$(git -C "$victim_repo" status --porcelain --untracked-files=all)" = "$victim_status_before" ] ||
		die "kernel build changed victim Git state in $reset_mode mode"
done

if "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
	--source git \
	--git-url "$fixture_repo" \
	--git-branch fixture \
	--expected-source-commit "$unexpected_commit" \
	--patch-dir "$patch_dir" \
	--work-dir "$work_dir" \
	--prepare-only > "$output_file" 2>&1; then
	die "kernel build script accepted an unexpected source commit"
fi

grep -Fq "Resolved kernel source does not match --expected-source-commit." "$output_file" ||
	die "kernel build script did not report the source-commit mismatch"
grep -Fq "Refusing to apply patches or start a build from an unexpected source commit." "$output_file" ||
	die "kernel build script did not report its fail-closed boundary"

cloned_source="$work_dir/source/git-fixture"
[ -d "$cloned_source/.git" ] || die "fixture source was not cloned"
[ "$(git -C "$cloned_source" rev-parse --verify 'HEAD^{commit}')" = "$actual_commit" ] ||
	die "cloned fixture source resolved to an unexpected commit"
git -C "$cloned_source" diff --quiet ||
	die "source-commit mismatch allowed a worktree mutation"
git -C "$cloned_source" diff --cached --quiet ||
	die "source-commit mismatch allowed an index mutation"
[ -z "$(git -C "$cloned_source" ls-files --others --exclude-standard)" ] ||
	die "source-commit mismatch allowed an untracked source mutation"
[ "$(sed -n '1p' "$cloned_source/guard.txt")" = "before" ] ||
	die "source-commit mismatch allowed the fixture patch to be applied"
[ ! -e "$work_dir/sp11-kernel-build-manifest.txt" ] ||
	die "source-commit mismatch allowed build manifest creation"
if grep -Fq "Applying patches from" "$output_file"; then
	die "source-commit mismatch reached patch application"
fi
if grep -Fq "Wrote build manifest" "$output_file"; then
	die "source-commit mismatch reached build preparation"
fi

git clone --quiet --bare "$fixture_repo" "$alternate_repo"
git -C "$cloned_source" remote set-url origin "$alternate_repo"

if "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
	--source git \
	--git-url "$fixture_repo" \
	--git-branch fixture \
	--expected-source-commit "$actual_commit" \
	--patch-dir "$patch_dir" \
	--work-dir "$work_dir" \
	--prepare-only > "$output_file" 2>&1; then
	die "kernel build script reused a checkout from an undeclared origin"
fi

grep -Fq "Existing source tree origin does not match --git-url" "$output_file" ||
	die "kernel build script did not report the reused-checkout origin mismatch"
grep -Fq "Rerun with --reset-source so retrieval provenance is unambiguous." "$output_file" ||
	die "kernel build script did not report the fail-closed origin recovery path"
[ "$(git -C "$cloned_source" remote get-url origin)" = "$alternate_repo" ] ||
	die "origin guard changed the existing checkout remote"
git -C "$cloned_source" diff --quiet ||
	die "origin mismatch allowed a worktree mutation"
git -C "$cloned_source" diff --cached --quiet ||
	die "origin mismatch allowed an index mutation"
[ "$(sed -n '1p' "$cloned_source/guard.txt")" = "before" ] ||
	die "origin mismatch allowed the fixture patch to be applied"
[ ! -e "$work_dir/sp11-kernel-build-manifest.txt" ] ||
	die "origin mismatch allowed build manifest creation"

printf 'Kernel source-path, source-commit, and reused-origin guards rejected unsafe inputs before patch or build mutation.\n'
