#!/usr/bin/env bash
set -euo pipefail

# This emitter deliberately depends only on the digest-pinned base image's
# shell/core utilities: Python is installed in the build container, not in the
# fresh network-disabled exporter. The host independently parses every byte.
fixture=false
stage=/work/.sp11-release-export-v1
tar_bin=/bin/tar
if [ "$#" -ne 0 ]; then
  [ "$#" -eq 4 ] && [ "$1" = --fixture-stage ] && [ "$3" = --fixture-tar ] &&
    [ "${SP11_RELEASE_STATE_EMITTER_FIXTURE:-false}" = true ] || {
    echo "release-state export fixture invocation is invalid" >&2
    exit 1
  }
  fixture=true
  stage="$2"
  tar_bin="$4"
  case "$stage" in
    /*/sp11-release-state-fixture.*/*) ;;
    *) echo "release-state export fixture root is invalid" >&2; exit 1 ;;
  esac
  case "$tar_bin" in
    /*) ;;
    *) echo "release-state export fixture tar is not absolute" >&2; exit 1 ;;
  esac
  [ -x "$tar_bin" ] && [ -f "$tar_bin" ] && [ ! -L "$tar_bin" ] || {
    echo "release-state export fixture tar is unsafe" >&2
    exit 1
  }
elif [ "$(uname -s)" != Linux ]; then
  echo "release-state export requires Linux" >&2
  exit 1
fi
unset SP11_RELEASE_STATE_EMITTER_FIXTURE

if [ "$fixture" = false ]; then
  [ -r /proc/self/mountinfo ] && [ ! -L /proc/self/mountinfo ] || {
    echo "release-state export cannot verify its mounts" >&2
    exit 1
  }
  awk '
  function has_option(options, wanted, count, values, slot) {
    count = split(options, values, ",")
    for (slot = 1; slot <= count; slot++) {
      if (values[slot] == wanted) return 1
    }
    return 0
  }
  $5 == "/work" {
    work_count++
    if (has_option($6, "ro")) work_ro++
    next
  }
  index($5, "/work/") == 1 { work_nested++ }
  $5 == "/repo" {
    repo_count++
    if (has_option($6, "ro")) repo_ro++
    next
  }
  index($5, "/repo/") == 1 { repo_nested++ }
  END {
    exit !(work_count == 1 && work_ro == 1 && work_nested == 0 &&
           repo_count == 1 && repo_ro == 1 && repo_nested == 0)
  }
' /proc/self/mountinfo || {
    echo "release-state export requires exact unshadowed read-only mounts" >&2
    exit 1
  }
fi

[ -d "$stage" ] && [ ! -L "$stage" ] &&
  [ -d "$stage/objects" ] && [ ! -L "$stage/objects" ] || {
  echo "release-state export staging is missing or unsafe" >&2
  exit 1
}
for control in catalog files.nul; do
  [ -f "$stage/$control" ] && [ ! -L "$stage/$control" ] || {
    echo "release-state export control is missing or unsafe" >&2
    exit 1
  }
done
if [ "$fixture" = true ] && [ "$(uname -s)" = Darwin ]; then
  catalog_size="$(stat -f '%z' "$stage/catalog")"
  list_size="$(stat -f '%z' "$stage/files.nul")"
else
  catalog_size="$(stat -c '%s' "$stage/catalog")"
  list_size="$(stat -c '%s' "$stage/files.nul")"
fi
[[ "$catalog_size" =~ ^[1-9][0-9]{0,6}$ ]] &&
  [ "$catalog_size" -le 4194304 ] &&
  [[ "$list_size" =~ ^[1-9][0-9]{0,5}$ ]] &&
  [ "$list_size" -le 131072 ] || {
  echo "release-state export controls exceed their bounds" >&2
  exit 1
}
unexpected="$(find "$stage" -mindepth 1 -maxdepth 1 \
  ! -name catalog ! -name files.nul ! -name objects -print -quit)"
[ -z "$unexpected" ] || {
  echo "release-state export staging has an unexpected member" >&2
  exit 1
}
object_count="$(awk -F ': ' '
  $1 == "Payload count" {
    if (seen++) exit 2
    print $2
  }
  END { if (seen != 1) exit 2 }
' "$stage/catalog")" || {
  echo "release-state export catalog count is invalid" >&2
  exit 1
}
[[ "$object_count" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$object_count" -le 4095 ] || {
  echo "release-state export object count is invalid" >&2
  exit 1
}
for ((index = 1; index <= object_count; index++)); do
  object_name="$(printf '%08d' "$index")"
  [ -f "$stage/objects/$object_name" ] && [ ! -L "$stage/objects/$object_name" ] || {
    echo "release-state export object set is incomplete or unsafe" >&2
    exit 1
  }
done
if [ "$fixture" = true ] && [ "$(uname -s)" = Darwin ]; then
  object_probe="$(
    find "$stage/objects" -mindepth 1 -maxdepth 1 -exec printf . \; |
      dd bs=1 count="$((object_count + 1))" 2>/dev/null
  )" || :
else
  object_probe="$(
    find "$stage/objects" -mindepth 1 -maxdepth 1 -printf . |
      dd bs=1 count="$((object_count + 1))" status=none
  )" || :
fi
[ "${#object_probe}" -eq "$object_count" ] || {
  echo "release-state export object set has an unexpected member" >&2
  exit 1
}
{
  printf 'catalog\0'
  for ((index = 1; index <= object_count; index++)); do
    printf 'objects/%08d\0' "$index"
  done
} | cmp -s - "$stage/files.nul" || {
  echo "release-state export member list is not canonical" >&2
  exit 1
}
tar_version="$("$tar_bin" --version)"
[ "${tar_version%%$'\n'*}" = 'tar (GNU tar) 1.35' ] || {
  echo "release-state export tar version is outside the pinned contract" >&2
  exit 1
}

unset TAR_OPTIONS TAPE RSH
export LC_ALL=C TZ=UTC
exec "$tar_bin" \
  -C "$stage" \
  --format=ustar \
  --blocking-factor=1 \
  --numeric-owner \
  --owner=0 \
  --group=0 \
  --mode=0644 \
  --mtime=@0 \
  --no-recursion \
  --hard-dereference \
  --null \
  --verbatim-files-from \
  -cf - \
  -T "$stage/files.nul"
