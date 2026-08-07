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

AUDIO_ASSETS_DIR="payload/audio"
OUT_DIR=""
RELEASE_NAME=""
LOCAL_DRAFT=false

MANIFEST_NAME="sp11-audio-topology-manifest.txt"
LOCAL_DRAFT_ROOT="build/local-drafts/audio"
AUDIOREACH_COMMIT="d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677"

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a nonpublishable local draft of the legacy Surface Pro 11 AudioReach
topology and ALSA UCM configuration assets.

This helper cannot prepare or publish a release. It copies the topology binary,
UCM profiles, and the source CMakeLists.txt into a local-draft directory with a
manifest, SHA256SUMS, and RELEASE-NOTES.md.

Options:
  --local-draft         Required acknowledgement that the output is a
                        nonpublishable local draft.
  --assets-dir DIR      Assets directory containing audio files,
                        default $AUDIO_ASSETS_DIR.
  --release-name NAME   Legacy draft label, default
                        sp11-audio-topology-v2-local-draft. It is not a tag.
  --out-dir DIR         Output directory. If omitted, defaults to
                        $LOCAL_DRAFT_ROOT/<release-name>.
  -h, --help            Show this help.

Output (under $LOCAL_DRAFT_ROOT/<release-name>/):
  X1E80100-Microsoft-Surface-Pro-11-tplg.bin
  MICROSOFT-Surface-Pro-11.conf
  Surface11-HiFi.conf
  x1e80100.conf
  CMakeLists.txt
  sp11-audio-topology-manifest.txt
  SHA256SUMS
  RELEASE-NOTES.md

EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

require_arg() {
  local opt="$1" val="${2:-}"
  if [ -z "$val" ]; then
    echo "$opt requires an argument." >&2
    usage >&2
    exit 2
  fi
}

file_size() {
  local size=""

  if size="$(stat -c '%s' "$1" 2>/dev/null)"; then
    :
  elif size="$(stat -f '%z' "$1" 2>/dev/null)"; then
    :
  else
    echo "Could not determine audio asset size: $1" >&2
    return 1
  fi

  case "$size" in
    ""|*[!0-9]*)
      echo "Audio asset size was not a nonnegative integer: $1" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$size"
}

reject_symlink_components() {
  local path="$1"
  local path_label="$2"
  local component=""
  local current=""

  case "$path" in
    /*)
      current="/"
      path="${path#/}"
      ;;
  esac

  while [ -n "$path" ]; do
    component="${path%%/*}"
    if [ "$path" = "$component" ]; then
      path=""
    else
      path="${path#*/}"
    fi

    case "$component" in
      ""|.) continue ;;
      ..)
        echo "Refusing parent traversal in $path_label: $1" >&2
        exit 1
        ;;
    esac

    if [ "$current" = "/" ]; then
      current="/$component"
    elif [ -n "$current" ]; then
      current="$current/$component"
    else
      current="$component"
    fi

    if [ -L "$current" ]; then
      echo "Refusing symlinked $path_label component: $current" >&2
      exit 1
    fi
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-draft)
      LOCAL_DRAFT=true
      shift
      ;;
    --assets-dir)
      require_arg "$1" "${2:-}"
      AUDIO_ASSETS_DIR="$2"
      shift 2
      ;;
    --release-name)
      require_arg "$1" "${2:-}"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --out-dir)
      require_arg "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$LOCAL_DRAFT" != "true" ]; then
  echo "Refusing to prepare audio artifacts without explicit --local-draft acknowledgement." >&2
  echo "This legacy helper only creates nonpublishable local drafts." >&2
  exit 2
fi

require_tool shasum
require_tool stat
require_tool git

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

reject_symlink_components "$AUDIO_ASSETS_DIR" "audio assets path"
if [ ! -d "$AUDIO_ASSETS_DIR" ]; then
  echo "Audio assets directory not found: $AUDIO_ASSETS_DIR" >&2
  exit 1
fi

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="sp11-audio-topology-v2-local-draft"
fi

release_root="$LOCAL_DRAFT_ROOT"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$release_root/$RELEASE_NAME"
fi

case "$OUT_DIR" in
  "$release_root"/*)
    out_leaf="${OUT_DIR#"$release_root"/}"
    ;;
  *)
    echo "Refusing output outside $release_root/: $OUT_DIR" >&2
    exit 1
    ;;
esac

case "$out_leaf" in
  ""|*/*|*..*|.*)
    echo "Refusing unsafe release output name: $out_leaf" >&2
    exit 1
    ;;
esac

reject_symlink_components "$release_root" "local-draft output root"
mkdir -p "$release_root"
release_root_abs="$(cd "$release_root" && pwd -P)"
expected_release_root="$repo_dir/$release_root"
if [ "$release_root_abs" != "$expected_release_root" ]; then
  echo "Refusing release output root outside repository: $release_root_abs" >&2
  exit 1
fi
OUT_DIR="$release_root_abs/$out_leaf"
OUT_DIR_DISPLAY="$release_root/$out_leaf"

if ! repo_commit="$(git rev-parse --verify 'HEAD^{commit}')"; then
  echo "Could not resolve the support repository HEAD commit." >&2
  exit 1
fi
if ! support_status="$(git status --porcelain --untracked-files=all)"; then
  echo "Could not determine the support repository status." >&2
  exit 1
fi
dirty="false"
if [ -n "$support_status" ]; then
  dirty="true"
fi

assets=(
  "X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
  "MICROSOFT-Surface-Pro-11.conf"
  "Surface11-HiFi.conf"
  "x1e80100.conf"
  "CMakeLists.txt"
)

missing=()
for asset in "${assets[@]}"; do
  asset_path="${AUDIO_ASSETS_DIR}/${asset}"
  if [ -L "$asset_path" ]; then
    echo "Refusing symlinked audio asset input: $asset_path" >&2
    exit 1
  fi
  if [ ! -e "$asset_path" ]; then
    missing+=("$asset")
  elif [ ! -f "$asset_path" ]; then
    echo "Refusing nonregular audio asset input: $asset_path" >&2
    exit 1
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing assets: ${missing[*]}" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

total_bytes=0
for asset in "${assets[@]}"; do
  cp "${AUDIO_ASSETS_DIR}/${asset}" "$OUT_DIR/${asset}"
  sz=$(file_size "${AUDIO_ASSETS_DIR}/${asset}")
  total_bytes=$((total_bytes + (sz > 0 ? sz : 0)))
done

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

manifest="$OUT_DIR/$MANIFEST_NAME"
{
  echo "# Surface Pro 11 Audio Topology Nonpublishable Local-Draft Manifest"
  echo
  echo "Artifact classification: NONPUBLISHABLE LOCAL DRAFT"
  echo "Publishable: no"
  echo "Generation mode: --local-draft"
  echo "Generated: $generated_at"
  echo "Draft label: $RELEASE_NAME"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Assets count: ${#assets[@]}"
  echo "Assets total bytes: $total_bytes"
  echo
  echo "Publication gate: blocked"
  echo "A future publishing flow requires a clean stable support HEAD, immutable"
  echo "tag and target binding, complete binary-to-source provenance, and confirmed"
  echo "redistribution and license terms. This helper establishes none of those gates."
  echo
  echo "## Topology Build Source"
  echo
  echo "Recorded upstream commit: $AUDIOREACH_COMMIT"
  echo "Upstream repo: https://github.com/linux-msm/audioreach-topology"
  echo "Binary-to-source binding verified by this helper: no"
  echo
  echo "## Assets"
  echo
  for asset in "${assets[@]}"; do
    hash=$(shasum -a 256 "${AUDIO_ASSETS_DIR}/${asset}" | awk '{print $1}')
    sz=$(file_size "${AUDIO_ASSETS_DIR}/${asset}")
    echo "- $asset"
    echo "  - Size: $sz bytes"
    echo "  - SHA256: $hash"
  done
  echo
  echo "## Build Command"
  echo
  echo "    m4 -I build -I . X1E80100-CRD.m4 > X1E80100-Microsoft-Surface-Pro-11.conf"
  echo "    alsatplg -c X1E80100-Microsoft-Surface-Pro-11.conf \\"
  echo "             -o X1E80100-Microsoft-Surface-Pro-11-tplg.bin"
} > "$manifest"

(
  cd "$OUT_DIR"
  shasum -a 256 ./*.bin ./*.conf ./CMakeLists.txt > SHA256SUMS
)

cat > "$OUT_DIR/RELEASE-NOTES.md" <<'EOF'
# NONPUBLISHABLE LOCAL DRAFT: Surface Pro 11 Audio Topology and UCM v2

> This directory is a nonpublishable local draft for development and review.
> Do not upload its contents as release assets. This legacy helper does not
> create a publishable release payload.

Publication remains blocked until a future flow binds a clean stable support
repository HEAD, immutable tag and target, exact binary sources, and confirmed
redistribution and license terms.

Prebuilt AudioReach topology binary and corrected ALSA UCM configuration for
the Microsoft Surface Pro 11 (Snapdragon X Elite, X1E80100).

Pair these files with the
[`7.1.3-jg-1sp11v2` kernel](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-1-v2).
That kernel makes the device-validated 2.4 MHz Denali DMIC clock the default;
UCM changes alone do not remove the static associated with the earlier 4.8 MHz
clock.

## Changes since v1

- Keep the same AudioReach topology binary built from upstream commit
  `d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677`.
- Match the Surface Pro 11's single WSA macro instead of including nonexistent
  WSA2 mixer paths.
- Expose two-channel internal-microphone capture.
- Set Surface-specific VA decoder gain to unity (0 dB) instead of the shared
  +16 dB default that clipped capture.

## What's included

| File | Purpose |
|---|---|
| `X1E80100-Microsoft-Surface-Pro-11-tplg.bin` | AudioReach DSP topology firmware |
| `MICROSOFT-Surface-Pro-11.conf` | ALSA UCM card profile |
| `Surface11-HiFi.conf` | UCM HiFi verb (speaker + mic) |
| `x1e80100.conf` | UCM card matcher with SP11 DMI regex |
| `CMakeLists.txt` | Build source for reproducibility |

## Install

```bash
# Verify
shasum -a 256 -c SHA256SUMS

# Install on target
sudo install -m 0644 -D X1E80100-Microsoft-Surface-Pro-11-tplg.bin \
  /lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin
sudo install -m 0644 -D MICROSOFT-Surface-Pro-11.conf \
  /usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf
sudo install -m 0644 -D Surface11-HiFi.conf \
  /usr/share/alsa/ucm2/Qualcomm/x1e80100/Surface11-HiFi.conf
sudo install -m 0644 -D x1e80100.conf \
  /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf

# Reboot for the topology and UCM configuration to load
sudo reboot
# After reboot:
systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
```

## Test

```bash
# Confirm UCM exposes both logical devices
alsaucm -c hw:0 set _verb HiFi
alsaucm -c hw:0 list _devices
wpctl status

# Low-volume 440Hz sine test (4 channels)
speaker-test -D hw:0,1 -c 4 -t sine -f 440 -l 3
```

## Provenance

The historical source recorded for `X1E80100-CRD.m4` is
[linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology)
at commit `d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677`. This helper does not prove
that the copied binary was built from that commit. See the local-draft metadata
in `sp11-audio-topology-manifest.txt`.

## Limitations

- A manual PipeWire speaker sink is still needed on the tested installation.
- Microphone capture is dramatically clearer with the linked 2.4 MHz kernel,
  but speech remains slightly tinny or thin.
- Speaker playback showed no audible regression with the 2.4 MHz kernel, but
  the current manual route can still sound distorted.
- Headphone, HDMI/DP, and external mic DAI links not wired in current DTS.
- Keep volume at 10-15% for first test; no speaker protection in UCM.
EOF

echo "NONPUBLISHABLE LOCAL DRAFT"
echo "Draft label: $RELEASE_NAME"
echo "Output: $OUT_DIR_DISPLAY"
echo "Support repo commit: $repo_commit"
echo "Support repo dirty: $dirty"
echo ""
echo "Files:"
for asset in "${assets[@]}" "$MANIFEST_NAME" "SHA256SUMS" "RELEASE-NOTES.md"; do
  printf "  %s\n" "$asset"
done
echo ""
echo "This output is for local development and review only; do not publish it."
