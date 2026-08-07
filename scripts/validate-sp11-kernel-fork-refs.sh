#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="${1:-$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env}"

usage() {
	cat <<EOF
Usage: $(basename "$0") [BASELINE]

Verify that the public thin-fork baseline and integration branches resolve to
the immutable commit declared by the kernel baseline configuration.
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

for tool in awk git; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

[ -f "$baseline" ] || die "kernel baseline not found: $baseline"

# shellcheck disable=SC1090
. "$baseline"

: "${SP11_KERNEL_FORK_URL:?baseline is missing SP11_KERNEL_FORK_URL}"
: "${SP11_KERNEL_FORK_BASE_REF:?baseline is missing SP11_KERNEL_FORK_BASE_REF}"
: "${SP11_KERNEL_FORK_BASE_COMMIT:?baseline is missing SP11_KERNEL_FORK_BASE_COMMIT}"
: "${SP11_KERNEL_FORK_INTEGRATION_REF:?baseline is missing SP11_KERNEL_FORK_INTEGRATION_REF}"
: "${SP11_KERNEL_FORK_INTEGRATION_COMMIT:?baseline is missing SP11_KERNEL_FORK_INTEGRATION_COMMIT}"

[[ "$SP11_KERNEL_FORK_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]] ||
	die "thin-fork URL must be a canonical HTTPS GitHub clone URL"
for ref in "$SP11_KERNEL_FORK_BASE_REF" "$SP11_KERNEL_FORK_INTEGRATION_REF"; do
	[[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
		die "invalid thin-fork branch name: $ref"
done
[ "$SP11_KERNEL_FORK_BASE_REF" != "$SP11_KERNEL_FORK_INTEGRATION_REF" ] ||
	die "thin-fork baseline and integration branches must be distinct"
for commit in "$SP11_KERNEL_FORK_BASE_COMMIT" "$SP11_KERNEL_FORK_INTEGRATION_COMMIT"; do
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
		die "each thin-fork commit must be a full lowercase 40-hex object ID"
done

base_remote_ref="refs/heads/$SP11_KERNEL_FORK_BASE_REF"
integration_remote_ref="refs/heads/$SP11_KERNEL_FORK_INTEGRATION_REF"
if ! remote_refs="$(git ls-remote --exit-code --heads "$SP11_KERNEL_FORK_URL" \
	"$base_remote_ref" "$integration_remote_ref")"; then
	die "could not resolve the declared public thin-fork branches"
fi

validate_remote_ref() {
	local branch="$1" expected_commit="$2"
	local remote_ref="refs/heads/$branch"
	local matches count resolved

	matches="$(awk -v expected_ref="$remote_ref" '$2 == expected_ref { print $1 }' <<< "$remote_refs")"
	count="$(awk 'NF { count++ } END { print count + 0 }' <<< "$matches")"
	[ "$count" -eq 1 ] ||
		die "expected exactly one remote result for $branch, found $count"
	resolved="$(awk 'NF { print; exit }' <<< "$matches")"
	[[ "$resolved" =~ ^[0-9a-f]{40}$ ]] ||
		die "remote branch $branch did not resolve to a full lowercase commit"
	[ "$resolved" = "$expected_commit" ] ||
		die "remote branch $branch resolved to $resolved, expected $expected_commit"

	printf 'Validated thin-fork branch %s at %s\n' "$branch" "$resolved"
}

validate_remote_ref "$SP11_KERNEL_FORK_BASE_REF" "$SP11_KERNEL_FORK_BASE_COMMIT"
validate_remote_ref "$SP11_KERNEL_FORK_INTEGRATION_REF" "$SP11_KERNEL_FORK_INTEGRATION_COMMIT"
