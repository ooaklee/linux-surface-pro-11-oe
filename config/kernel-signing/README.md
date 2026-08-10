# SP11 module-signing public certificate

This directory contains public trust material only. The approved release
certificate is [`sp11-module-signing-cert.pem`](sp11-module-signing-cert.pem).
Its canonical DER SHA-256 is
`8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b`.

[`sp11-module-signing-allowed-unsigned.txt`](sp11-module-signing-allowed-unsigned.txt)
is the exact, bytewise-sorted set of Ubuntu-policy `drivers/staging/` modules
that may remain unsigned. Its 85 LF-terminated rows have SHA-256
`eb507e006b37ad7d291a37524f3f2f6b5281c5a3f98738dc07056a3ca7cba800`.
Release validation rejects a missing, additional, duplicate, reordered, or
otherwise different path. This bounded exception is permitted only while
Secure Boot and forced module-signature enforcement remain disabled.

Never add a private key, PIN, password, combined key/certificate PEM, generated
replacement certificate, or secret-store reference here. Private signing
material remains outside Git under the custody model in
[ADR0056](../../docs/adr/adr-0056-controlled-sp11-module-signing.md). A key or
certificate rotation—or a change to the unsigned-path policy—requires a new
ABI, reviewed baseline, fresh reproducible build pair, and new release
candidate.
