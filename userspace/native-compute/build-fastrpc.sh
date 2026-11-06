#!/usr/bin/env bash
# Recover/install and verify the FastRPC artifacts observed on 2026-11-06.
# The original compiler commands are UNKNOWN: no source/build tree was retained.
# DWARF records /src/fastrpc-src/src and Ubuntu GCC 13.3.0; this does not prove
# an on-device build. Do not present this script as a verified source rebuild.
# Matching upstream family: https://github.com/qualcomm/fastrpc (see NPU-BRINGUP.md).
# No reconstructed configure/make recipe is executed here.
set -euo pipefail

usage() {
  printf 'Usage: %s [--verify | --install-archive /tmp/fastrpc-libs.tar.gz]\n' "$0"
}

mode=${1:---verify}
case "$mode" in
  --verify) [[ $# -le 1 ]] || { usage >&2; exit 2; } ;;
  --install-archive) [[ $# -eq 2 ]] || { usage >&2; exit 2; } ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ $(uname -m) == aarch64 ]] || { printf 'Run on the aarch64 Surface.\n' >&2; exit 1; }
export QNN_SDK_ROOT=${QNN_SDK_ROOT:-$HOME/qairt/2.51.0.260929}
libdir=$HOME/qairt/lib-local

if [[ $mode == --install-archive ]]; then
  archive=$2
  # Pin the inspected archive, including its twelve flat entries and symlinks.
  archive_hash=$(sha256sum -- "$archive")
  [[ ${archive_hash%% *} == 28a718aaa38ddbabfee8ca06b3d90a79a7d6084f778b6a1697b563d56c5c587a ]] || {
    printf 'Archive differs from the verified 2026-11-06 artifacts.\n' >&2
    exit 1
  }
  mkdir -p "$libdir"
  # Reinstallation from the retained archive was exercised during round 4.
  # It writes only under ~/qairt; no system install, services, or root access.
  tar --no-same-owner -xzf "$archive" -C "$libdir"
fi

cd "$libdir"
sha256sum --check <<'HASHES'
765a0d1af713a17094702dcad9231d9eca8f30dbcccf7e00b5594b01930eaddc  libadsp_default_listener.so.1.0.0
624a3543dd6cc73c2e81a4a34e34b534288b6d4f5bcf6cb430968035b4b576da  libadsprpc.so.1.0.0
ea8f9c61de428039fc0caec26ba437a2aa9a0df8a668892dd6d7437fcb5c6108  libcdsp_default_listener.so.1.0.0
04091fe0ab1251d62456efe945ae0b96303035accb3cee85521fc2d294692340  libcdsprpc.so.1.0.0
HASHES
for name in libadsprpc libcdsprpc libadsp_default_listener libcdsp_default_listener; do
  for suffix in .so .so.1; do
    [[ -L $name$suffix && $(readlink "$name$suffix") == "$name.so.1.0.0" ]] || {
      printf 'Unexpected link: %s\n' "$name$suffix" >&2
      exit 1
    }
  done
done

export LD_LIBRARY_PATH="$libdir:$QNN_SDK_ROOT/lib/aarch64-oe-linux-gcc11.2"
export ADSP_LIBRARY_PATH="$QNN_SDK_ROOT/lib/hexagon-v73/unsigned;/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp"
export PATH="$QNN_SDK_ROOT/bin/aarch64-oe-linux-gcc11.2:$PATH"
test -f "$QNN_SDK_ROOT/lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so"
printf 'LD_LIBRARY_PATH=%s\nADSP_LIBRARY_PATH=%s\n' "$LD_LIBRARY_PATH" "$ADSP_LIBRARY_PATH"
ldd ./libcdsprpc.so

# Keep validator output files under /tmp, not its default working directory.
# Nonzero is propagated: round 4 returned 255 with unit test -6/testsig.
workdir=$(mktemp -d /tmp/fastrpc-verify.XXXXXX)
printf 'Validator working directory: %s\n' "$workdir"
cd "$workdir"
qnn-platform-validator --backend dsp --libVersion --coreVersion --testBackend
