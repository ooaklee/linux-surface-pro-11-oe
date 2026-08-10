# Surface Pro 11 controlled release-signing patch

This release-only patch gives the candidate the co-installable Debian version
`7.2-rc5-jg-0sp11v3r2` and kernel ABI
`7.2-rc5-jg-0sp11v3r2-qcom-x1e`. It replaces Kbuild's clean-build ephemeral
module-signing key with the fixed container path required by the
`sp11-controlled-rsa4096-sha512-v1` policy.

Apply this directory after `patches/jglathe-qcom-x1e-7.2-rc5` and
`patches/sp11-qcom-x1e-7.2-rc5-v3`. The Docker release wrapper mounts the
validated encrypted key/certificate bundle and PIN read-only. No private key,
PIN, or host path is part of this patch or the resulting source archive.
