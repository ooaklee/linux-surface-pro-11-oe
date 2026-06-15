#!/usr/bin/env bash
set -euo pipefail

AUDIO_ASSETS_DIR="payload/audio"
OUT_DIR=""
RELEASE_NAME=""
RELEASE_NOTES=""

MANIFEST_NAME="sp11-audio-topology-manifest.txt"

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for the Surface Pro 11
AudioReach topology and ALSA UCM configuration.

It copies the topology binary, UCM profiles, and the source CMakeLists.txt
into a release directory with a manifest, SHA256SUMS, and RELEASE-NOTES.md.
It does not publish anything.

Options:
  --assets-dir DIR      Assets directory containing audio files,
                        default $AUDIO_ASSETS_DIR.
  --release-name NAME   Release/tag name (required).
  --out-dir DIR         Output directory. If omitted, defaults to
                        build/release/<release-name>.
  -h, --help            Show this help.

Output (under build/release/<release-name>/):
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

while [ "$#" -gt 0 ]; do
  case "$1" in
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

require_tool shasum
require_tool stat

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

if [ ! -d "$AUDIO_ASSETS_DIR" ]; then
  echo "Audio assets directory not found: $AUDIO_ASSETS_DIR" >&2
  exit 1
fi

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="sp11-audio-topology-v1"
fi

release_root="build/release"
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

if [ -L "build" ] || [ -L "$release_root" ]; then
  echo "Refusing symlinked release output root: $release_root" >&2
  exit 1
fi

mkdir -p "$release_root"
release_root_abs="$(cd "$release_root" && pwd -P)"
expected_release_root="$repo_dir/$release_root"
if [ "$release_root_abs" != "$expected_release_root" ]; then
  echo "Refusing release output root outside repository: $release_root_abs" >&2
  exit 1
fi
OUT_DIR="$release_root_abs/$out_leaf"
OUT_DIR_DISPLAY="$release_root/$out_leaf"

repo_commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty="false"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
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
  if [ ! -f "${AUDIO_ASSETS_DIR}/${asset}" ]; then
    missing+=("$asset")
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
  sz=$(stat -c%s "${AUDIO_ASSETS_DIR}/${asset}" 2>/dev/null)
  total_bytes=$((total_bytes + (sz > 0 ? sz : 0)))
done

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

manifest="$OUT_DIR/$MANIFEST_NAME"
{
  echo "# Surface Pro 11 Audio Topology Release Manifest"
  echo
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Assets count: ${#assets[@]}"
  echo "Assets total bytes: $total_bytes"
  echo
  echo "## Topology Build Source"
  echo
  echo "Pinned upstream commit: d7a5e9d"
  echo "Upstream repo: https://github.com/linux-msm/audioreach-topology"
  echo
  echo "## Assets"
  echo
  for asset in "${assets[@]}"; do
    hash=$(shasum -a 256 "${AUDIO_ASSETS_DIR}/${asset}" | awk '{print $1}')
    sz=$(stat -c%s "${AUDIO_ASSETS_DIR}/${asset}" 2>/dev/null)
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
# Surface Pro 11 Audio Topology and UCM

Experimental prebuilt AudioReach topology binary and ALSA UCM configuration for
the Microsoft Surface Pro 11 (Snapdragon X Elite, X1E80100).

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

# Reboot for topology to load, then restart PipeWire
sudo reboot
# After reboot:
systemctl --user restart pipewire wireplumber
```

## Test

```bash
# Enable DSP route
amixer -c0 cset numid=68 'on'

# Low-volume 440Hz sine test (4 channels)
speaker-test -D hw:0,1 -c 4 -t sine -f 440 -l 3
```

## Provenance

Built from `X1E80100-CRD.m4` in
[linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology)
at commit `d7a5e9d`. See `sp11-audio-topology-manifest.txt` for full metadata.

## Limitations

- PipeWire ACP auto-profile is `false` — manual sink config may be needed.
- Headphone, HDMI/DP, and external mic DAI links not wired in current DTS.
- Keep volume at 10-15% for first test; no speaker protection in UCM.
EOF

echo "Release: $RELEASE_NAME"
echo "Output: $OUT_DIR_DISPLAY"
echo "Support repo commit: $repo_commit"
echo "Support repo dirty: $dirty"
echo ""
echo "Files:"
for asset in "${assets[@]}" "$MANIFEST_NAME" "SHA256SUMS" "RELEASE-NOTES.md"; do
  printf "  %s\n" "$asset"
done
echo ""
echo "To publish (manual):"
echo "  gh release create $RELEASE_NAME $OUT_DIR_DISPLAY/* \\"
echo "    --title \"Audio Topology $RELEASE_NAME\" \\"
echo "    --notes \"SP11 AudioReach topology and UCM config\""
