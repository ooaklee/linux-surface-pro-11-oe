#!/usr/bin/env bash
# QAIRT SDK install for the Surface Pro 11 OE image — VERIFIED steps for the
# 2.51.0.260929 zip distribution (supersedes the blocked 2.31 QIK flow).
#
# Usage (on the device):
#   install-qairt.sh /tmp/qairt-subset.tar.gz
# The tarball is staged on a host from the fully extracted zip:
#   tar -czf qairt-subset.tar.gz -C <extracted-zip-parent> \
#     2.51.0.260929/bin/aarch64-oe-linux-gcc11.2 \
#     2.51.0.260929/lib/aarch64-oe-linux-gcc11.2 \
#     2.51.0.260929/lib/hexagon-v73 2.51.0.260929/lib/hexagon-v75 \
#     2.51.0.260929/lib/hexagon-v79 2.51.0.260929/include \
#     2.51.0.260929/examples/QNN/converter/models \
#     2.51.0.260929/examples/QNN/NetRun
# Transfer: scp -P <port> qairt-subset.tar.gz user@device:/tmp/
set -euo pipefail

TARBALL=${1:-}
INSTALL_ROOT=${QNN_INSTALL_ROOT:-$HOME/qairt}
SDK_VERSION=2.51.0.260929

if [[ -z $TARBALL || ! -f $TARBALL || ! -r $TARBALL ]]; then
    printf 'Usage: %s /path/to/qairt-subset.tar.gz\n' "$0" >&2
    exit 1
fi

mkdir -p "$INSTALL_ROOT"
tar xzf "$TARBALL" -C "$INSTALL_ROOT"
R=$INSTALL_ROOT/$SDK_VERSION

# Sanity: required host-side libs (stubs live here, NOT under hexagon-*)
for lib in libQnnHtp.so libQnnHtpPrepare.so libQnnHtpV73Stub.so; do
    [[ -f $R/lib/aarch64-oe-linux-gcc11.2/$lib ]] || {
        printf 'Missing %s — tarball does not match the verified layout\n' "$lib" >&2
        exit 1
    }
done
# Skels live under lib/hexagon-v73/unsigned (there is no lib/hexagon-v73/dsp)
[[ -f $R/lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so ]] || {
    printf 'Missing libQnnHtpV73Skel.so under lib/hexagon-v73/unsigned\n' >&2
    exit 1
}

cat <<EOF
Installed to $R ($(du -sh "$R" | cut -f1)).

Verified environment:
  export QNN_SDK_ROOT=$R
  export LD_LIBRARY_PATH=$R/lib/aarch64-oe-linux-gcc11.2
  export ADSP_LIBRARY_PATH=$R/lib/hexagon-v73/unsigned

Validate (KNOWN TO FAIL on this image until libcdsprpc.so is provided):
  \$QNN_SDK_ROOT/bin/aarch64-oe-linux-gcc11.2/qnn-platform-validator --backend dsp

Known blockers (verified 2026-11-05):
  - qnn-platform-validator --backend dsp: "Missing shared libraries:
    libcdsprpc.so" — the userspace FastRPC shim is not in this zip and not on
    the device image. DSP/HTP execution is blocked on it.
  - The zip ships no prebuilt runnable model; qnn-net-run needs a model built
    with qairt-converter (x86_64 host tool) or a compiled sample-app.
EOF
