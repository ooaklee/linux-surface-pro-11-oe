#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""
temporary_parent=""

cleanup() {
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

for tool in cmp git grep mktemp; do
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

printf '%s\n' \
	'diff --git a/guard.txt b/guard.txt' \
	'--- a/guard.txt' \
	'+++ b/guard.txt' \
	'@@ -1 +1 @@' \
	'-before' \
	'+after' > "$patch_dir/0001-change-guard-marker.patch"

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

unexpected_commit="0000000000000000000000000000000000000000"
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
