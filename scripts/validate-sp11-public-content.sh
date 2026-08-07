#!/usr/bin/env bash
set -euo pipefail

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_WORK_TREE
  for variable_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
    unset "$variable_name"
  done
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_ATTR_NOSYSTEM=1
  export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

explicit_files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      if [ -z "${2:-}" ]; then
        echo "error: --file requires a path" >&2
        exit 2
      fi
      explicit_files+=("$2")
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--file PATH ...]"
      exit 0
      ;;
    *)
      echo "error: unknown public-content validator option" >&2
      exit 2
      ;;
  esac
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: public-content validation requires a git worktree" >&2
  exit 1
fi

# Print only file names. A CI log must not echo a secret that this check finds.
prohibited_pattern='(/Users/[[:alnum:]_.-]+/|/home/[[:alnum:]_.-]+/|[[:alnum:].-]+\.ngrok(-free)?\.(app|io)(:[0-9]+)?|BEGIN ((RSA|OPENSSH|EC|DSA) )?PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|AnyDesk|Live Share)'

matches=""
if [ "${#explicit_files[@]}" -gt 0 ]; then
  explicit_index=0
  for path in "${explicit_files[@]}"; do
    explicit_index=$((explicit_index + 1))
    if [ ! -s "$path" ] || [ ! -f "$path" ] || [ -L "$path" ]; then
      echo "error: public text input $explicit_index must be a nonempty regular, non-symlinked file" >&2
      exit 1
    fi
    if ! grep -Iq . "$path"; then
      echo "error: public text input $explicit_index is not nonempty text" >&2
      exit 1
    fi
    if grep -IqE "$prohibited_pattern" "$path"; then
      matches="${matches}${matches:+$'\n'}public text input ${explicit_index}"
    fi
  done
else
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
fi

if [ -n "$matches" ]; then
  echo "error: public content contains a private-path, endpoint, remote-tool, or credential pattern:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi

echo "Public-content hygiene checks passed."
