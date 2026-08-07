#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: public-content validation requires a git worktree" >&2
  exit 1
fi

# Print only file names. A CI log must not echo a secret that this check finds.
prohibited_pattern='(/Users/[[:alnum:]_.-]+/|/home/[[:alnum:]_.-]+/|[[:alnum:].-]+\.ngrok(-free)?\.(app|io)(:[0-9]+)?|BEGIN ((RSA|OPENSSH|EC|DSA) )?PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|AnyDesk|Live Share)'

matches=""
while IFS= read -r -d '' path; do
  [ -f "$path" ] || continue
  case "$path" in
    scripts/validate-sp11-public-content.sh)
      # This validator necessarily contains the patterns it checks.
      continue
      ;;
  esac
  if grep -IqE "$prohibited_pattern" "$path"; then
    matches="${matches}${matches:+$'\n'}${path}"
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if [ -n "$matches" ]; then
  echo "error: tracked public content contains a private-path, endpoint, remote-tool, or credential pattern:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi

echo "Public-content hygiene checks passed."
