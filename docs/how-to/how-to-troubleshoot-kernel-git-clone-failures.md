---
id: how-to-troubleshoot-kernel-git-clone-failures
title: "Troubleshoot Kernel Source Fetch Failures"
# prettier-ignore
description: Diagnose and recover a native linux-armer kernel build whose reviewed Git source cannot be fetched.
---

# How To: Troubleshoot Kernel Source Fetch Failures

Last reviewed: 2026-08-30

Use this procedure when `linux-armer kernel build` stops while resolving or
fetching its kernel source. Preserve the first Git error and the exact reviewed
repository/ref pair.

## Check the host and remote without changing state

```sh
linux-armer doctor --workspace .
git ls-remote https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  <reviewed-ref>
```

An empty `ls-remote` result means the requested ref is not advertised. An
authentication prompt for this public source, TLS failure or connection reset
points to local proxy, certificate, DNS or network policy rather than the
kernel recipe.

Do not place credentials in a repository URL, command log or public issue.
Inspect any configured proxy or credential helper locally and redact it from
reports.

## Review the native build plan

```sh
linux-armer kernel build \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch <reviewed-ref> \
  --work-dir build/linux-armer/kernel-work \
  --output-dir build/linux-armer/kernel-fetch-retry \
  --dry-run
```

Confirm that the URL and ref are exactly the intended inputs. A branch name is
mutable; record the resolved commit from the successful build before treating
its output as release evidence.

## Recover a partial CLI-owned source

After fixing the network or ref, reset only the CLI-owned cached source:

```sh
linux-armer kernel build \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch <reviewed-ref> \
  --work-dir build/linux-armer/kernel-work \
  --output-dir build/linux-armer/kernel-fetch-retry \
  --reset-source
```

`--reset-source` does not alter a host checkout. Ensure no other build is using
the same work directory, and always use a fresh output directory.

If the same fetch fails repeatedly, try a different trusted network or Docker
daemon and retain the first redacted failure. Do not bypass TLS verification,
replace the source with an unreviewed mirror, or publish an incomplete output.

## Verify recovery

```sh
linux-armer kernel inspect build/linux-armer/kernel-fetch-retry
```

The build is recovered only when it publishes a complete ABI-bound bundle and
inspection succeeds.
