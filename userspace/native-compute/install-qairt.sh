#!/usr/bin/env bash
# QAIRT 2.31 QCC+ QIK extraction remains blocked on the tested device.
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
# The tested Linux QIK starts with QCC+ and could not be extracted by the
# available tools. Do not run an unknown payload or modify an installation.
if [[ $(LC_ALL=C head -c 4 "$1") == 'QCC+' ]]; then
    printf '%s\n' 'QCC+ container detected; bash and unsquashfs did not extract the tested QIK.' >&2
fi
printf '%s\n' \
    'Installation blocked: no extraction method has been verified for this QIK.' \
    'See README.md for tested probes and device results.' >&2
exit 1
