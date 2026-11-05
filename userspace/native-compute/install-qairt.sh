#!/usr/bin/env bash
# QAIRT 2.31 QIK installation is blocked until a Linux QIK method is tested.
set -euo pipefail

if (( $# == 0 )); then
    printf '%s\n' 'Manually download the SDK (login and EULA required):' \
        'https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk' >&2
    exit 1
fi
if (( $# != 1 )); then
    printf 'Usage: %s /path/to/file.qik\n' "$0" >&2
    exit 1
fi
if [[ ! -f $1 || ! -r $1 ]]; then
    printf 'Cannot read QIK file: %s\n' "$1" >&2
    exit 1
fi
# QCC+ is a proprietary container, not an executable shell installer. No
# extraction command is known to work yet; do not guess or modify an install.
printf '%s\n' \
    'Installation blocked: no extraction method has been verified for this QIK.' \
    'A Linux QIK/QPM runtime or other on-device tooling is needed; see README.md.' >&2
exit 1
