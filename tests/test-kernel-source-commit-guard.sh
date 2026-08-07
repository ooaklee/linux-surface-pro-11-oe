#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_root=""

cleanup() {
	[ -n "$temporary_root" ] || return 0
	case "$temporary_root" in
		"${TMPDIR:-/tmp}"/sp11-source-guard.*)
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

for tool in git grep mktemp; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-source-guard.XXXXXX")"
fixture_repo="$temporary_root/source-repository"
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

printf 'Kernel source-commit guard rejected a mismatch before patch or build mutation.\n'
