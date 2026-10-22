Native math through FastRPC: raw source proof-of-concept
======================================================

This kit contains source for a small, typed sum/max interface and an offline
build-and-check path. It is a foundation for native CPU-to-DSP work, not an
installable driver, a qualified DSP package, an NPU/HTP inference backend, or
proof that a particular device can load or execute the result.

At composition time this source delivery has not earned a fresh build result.
Prior finite software checks motivated the source and checks included here;
their receipts do not substitute for building this exact delivered tree.
Successful future build receipts also do not establish hardware compatibility.

What is included
----------------

  upstream/qaic/       QAIC compiler, file2hs, templates and IDL source inputs
  upstream/fastrpc/    Source-only Linux libcdsprpc build closure and IDLs
  native/idl/         sp11_native_compute_v1 sum/max interface
  native/dsp/         Stateless bounded implementation
  native/host/        Intent-validating launcher and active RPC worker source
  native/include/     Checked host-call API and the 4096-element limit
  native/tests/       Pure implementation, layout and mock-control checks
  native/freestanding/include/
                      Four declaration-only headers for analysis compilation
  native/patches/     Call-local FastRPC capability-query scratch-state patch
  interfaces/linux/  Public FastRPC kernel UAPI header, not kernel implementation
  tools/             Portable offline build/check scripts
  toolchain/         Optional public dependency-image recipe
  LICENSES/          Component licence texts; also read NOTICE.txt

SOURCE-PROVENANCE.json records these upstream origins and exact revisions:

  https://github.com/qualcomm/QAIC
    a66a0019fb488abae955bbc9b3a9de3dc15962d0
  https://github.com/qualcomm/fastrpc
    a56e9d4de3614a8d8f4b0e15ff561350c4b686e3

The upstream base files are retained unchanged. The capability-query patch is
applied only to a fresh writable FastRPC build copy. QAIC build-copy metadata
labels the revision as a source export; it does not invent a Git checkout or
silently borrow an enclosing repository's commit.

SOURCE-MANIFEST.json lists source/support file hashes, sizes and raw modes.
SHA256SUMS covers those files plus the manifest, excluding only itself. Verify
the kit's externally supplied checksum through a trusted channel before
executing bundled tools. The scripts check complete manifest/checksum closure;
internal consistency alone is not a signature or proof of download authenticity.

No Windows DLL, proprietary SDK binary, firmware image, device-specific factory
data or prebuilt test library is supplied or needed for this offline build.
Conditional Windows branches remain in portable upstream source. The source
kit does not include dependency-container layers or Ubuntu binary packages.

Build prerequisites
-------------------

Use native Linux ARM64 (uname machine aarch64), as a nonroot user. This recipe
is not a cross-build from an x86 host and does not use a Windows toolchain.
The public reference dependency recipe is Ubuntu 24.04 ARM64. Its explicit
package names are:

  build-essential autoconf automake libtool pkg-config libyaml-dev libbsd-dev
  clang-19 lld-19 llvm-19 ghc cabal-install libghc-syb-dev ca-certificates
  git file python3 patch

Install/provision dependencies separately, with authorization appropriate to
your environment. The normal builder does not invoke APT, download packages,
clone repositories, install services or install its output. Cabal is configured
with no active remote repositories; required Haskell packages must already be
available. Tool/package observations are recorded, not silently equated with
every other compiler distribution or version.

The optional toolchain/Dockerfile pins public base-image digests and uses the
timestamped HTTPS Ubuntu archive in toolchain/ubuntu.sources. Building that
dependency image requires network access and is distinct from an offline kit
build. Keep TLS and archive-signature verification enabled. The existence of
the recipe is not a claim that its latest build has succeeded.

Paths must be absolute and canonical, with no whitespace, colon or backslash;
these restrictions come from upstream Make and the fixed dependency grammar.
Use an existing writable parent outside the kit with at least 2 GiB free. The
new output directory must be owned by the build user, mode 0700 and empty; the
builder creates it if absent. Do not reuse another build's output or place it
inside the kit. Keep the kit read-only while building.

Build command
-------------

Start in the kit root. Replace the quoted parent placeholder with an existing
directory you own. Choose a new output name if native-compute-build already
exists. The subshell keeps failure/settings local to this command block.

  (
    set -eu
    KIT=$(pwd -P)
    BUILD_PARENT=$(cd '<existing-writable-build-parent>' && pwd -P)
    OUTPUT="$BUILD_PARENT/native-compute-build"
    test ! -e "$OUTPUT"
    test ! -L "$OUTPUT"
    python3 -I -B "$KIT/tools/build.py" \
      --kit "$KIT" --output "$OUTPUT" --isa v73
  )

Only --isa v73 is supported by this analysis profile. That argument selects
code generation; it is not an observation of the attached or intended DSP.
The tools create their own HOME, temporary and Cabal directories under output.
No machine-specific shell PATH wrapper or SDK environment is required.

For optional container isolation, build the supplied dependency recipe for
Linux ARM64, then run the same command with networking disabled, a read-only
root filesystem, no added capabilities or devices, the kit mounted read-only,
and only a fresh output parent writable by the nonroot container user. Confirm
ownership as seen inside the container; do not assume a host chown is effective
on every shared filesystem. Do not mount a Docker socket, device nodes, firmware
directories or host SDK binaries. Provide writable temporary space as needed.
The helpers have finite deadlines and sampled space/output guards, not hard
filesystem quotas or a universal descendant-reaping guarantee; an isolated job
or container remains the final process/resource boundary.

What the command actually does
------------------------------

The CPU stage freshly builds QAIC/file2hs and target-only libcdsprpc, generates
the exact header/AP stub/DSP skeleton, and compiles the following local checks:

  * A dual-header FastRPC capability UAPI layout check. It checks the included
    public header and userspace definitions, not the running kernel or device.
  * 60 pure implementation checks for sum/max, values, handles and error bounds.
    This executable calls the implementation directly on the CPU, without RPC.
  * 23 mock client-control scenarios, using explicit replacement capability,
    allocation, open/invoke/close functions. They exercise client decisions,
    cleanup and error precedence, not a real SDK, transport or DSP response.
    The original 21 cases remain, with two additional empty-argv/null-name
    usage rejections proving safe fallback diagnostics and no mock RPC calls.
  * 266 checked-host-API assertions over 50 rejected and 18 forwarded calls.
    These link the real checked wrapper against input-blind raw-function mocks,
    not the generated stub or SDK. They cover negative/oversized counts, null
    pointers, empty-input rules, exact 64-bit handle/argument forwarding,
    unchanged status codes and partial output on a backend error.
  * 32 AP-wire cases / 708 assertions using the genuine generated AP stub,
    linked only to local transport and
    logging mocks, not libcdsprpc or the DSP implementation. It checks the
    method/scalar encoding, count bytes, input pointer and byte length, scratch
    output width, success copy-out and transport-error behaviour. These are
    local marshaling checks, not a real FastRPC transport or remote result.
    There are 18 admitted wire cases and 14 locally rejected cases; both positive
    and negative mock transport errors fill scratch but must leave caller
    output/canaries unchanged. The default runtime logger path is mocked, not
    compiled out. Exact input pointer and extent are checked, not an independent
    comparison of every input element. Open/close mock traps enforce that this
    fixture does not open a remote handle; their pass-through is not tested.

The genuine generated AP stub and libcdsprpc are linked into an internal native
compute-rpc-worker, which is LINK-ONLY: the builder never executes it or runs
its linked-library constructors. Its main uses the same pure argument parser
as the public launcher, then retains the capability, architecture, unsigned-PD,
checked-call and cleanup gates. The mock-control executable instead runs a
separately compiled client main plus the checked wrapper, with mocks and no
generated stub/libcdsprpc. Its two raw empty-max fault scenarios now verify
that neither raw outcome can be reached: empty max is rejected locally, and
the client still completes its valid vectors and closes the handle.
There is no shipping CPU fallback pretending to be a successful DSP call.

The public compute-client is now a separately linked libc-only launcher. This
separation matters: this FastRPC library has startup constructors which can
open DMA-heap/FastRPC device resources BEFORE an SDK-linked main validates its
arguments. Calling the internal worker with --help or invalid arguments is
therefore NOT a passive operation. Do not execute the internal worker directly
as a probe, and do not test a genuine SDK-linked binary merely for its usage.

The launcher validates the exact --run-cdsp --expect-arch 0xNN syntax and paired
architecture before locating or executing the worker. It obtains its own path
from bounded Linux /proc/self/exe, derives the fixed sibling compute-rpc-worker
basename, and uses execv without a shell, PATH search, argv[0] path selection or
fallback. Missing procfs, truncated paths and exec failures stop with failure.
An empty argument vector or null program name uses compute-client in the usage
diagnostic instead of passing a null pointer to a string formatter.
Legacy numeric forms already admitted by the shared parser, such as 0x073 for
the v73 candidate, are unchanged. An admitted run is ACTIVE: the worker's SDK
constructors may open resources before its subsequent capability queries.

This boundary assumes an ordinary unprivileged process, trusted launcher/worker
files and a trusted dynamic-loader environment. Deterministic sibling lookup
is not package authentication or protection against a changed installation
tree, LD_PRELOAD or other externally injected code. No elevated/setuid install
is supplied. The source manifest binds the parser and both build commands;
an eventual deployment must preserve their architecture and package pairing.
If Linux appends a " (deleted)" suffix after the launcher is unlinked, lookup
still uses the reported parent directory. This is not file authentication or
an atomic update protocol; the trusted-tree requirement remains.

The build inspects the launcher and local mock worker for libc-only ELF
dependencies BEFORE testing. It executes copies of the genuine launcher only
in separate fixture directories with a local mock worker, never beside the
genuine SDK worker. The 27 planned cases comprise 20 rejected intents, six
admitted local dispatches and one missing-worker failure. Every case places the
local impostor directory first in PATH. Tests cover local process dispatch,
argument/path resolution and process exit propagation. Mock constructor text
is explicitly local test data, not an SDK startup or DSP result. The actual
SDK worker remains link-only; these tests do not qualify a DSP runtime.
Receipt field rpcClientExecuted refers to that genuine SDK worker; the separate
publicLauncherExecutedWithMockWorker field records the local launcher fixture.

The additional AP-wire fixture DOES execute the genuine generated AP stub on
the CPU, ending at explicit remote_handle64_* mocks. It is distinct from both
the input-blind checked-API fixture and the genuine SDK-linked client. Its ELF
dependencies and defined mock/generated/checked symbols are inspected before
execution; it does not link libcdsprpc or run that library's constructors.
The returned output bytes are fixed mock data, not DSP arithmetic results.
In this genuine stub, a nonzero mock transport return skips copying its local
output scratch to the caller, even if the mock filled that scratch. This is
a generated-stub contract; it does not override the checked wrapper's general
promise to preserve any output changes made by whatever raw API it calls.

Authored C and its units, including the DSP implementation, use strict
C11/pedantic warning checks. The generated third-party AP stub and DSP skeleton
use GNU11 with Wall/Wextra/Werror because the generator's FARF macros
use GNU comma elision. This is a scoped language-dialect choice, not suppression
of all compiler diagnostics. Raw QAIC, Autotools and compiler diagnostics are
retained for review; successful exit does not mean a warning-free build.

The DSP implementation uses fixed-width int32_t input, int64_t sum and int32_t
maximum, with at most 4096 elements and a validated stateless opaque handle.
Empty sum is zero; empty max is an error. The general generated AP stub remains
unchanged and does not enforce the element limit or negative-length rejection
before RPC. Host applications must include sp11_compute_checked.h and use
sp11_native_compute_v1_sum_checked / sp11_native_compute_v1_max_checked,
compiling native/host/compute-checked.c with include paths for native/include,
the generated header and FastRPC headers. The example client uses these checked
entry points. Direct calls to raw generated sum/max symbols bypass admission.

The checked API rejects invalid counts and null-pointer combinations with
AEE_EBADPARM before calling the generated function or touching output storage.
Sum admits 0..4096 elements (a null input is allowed only at zero); max admits
1..4096. Empty sum is still forwarded, never computed as a host fallback.
Every admitted call forwards its opaque handle and pointers unchanged once,
including raw error codes and any output already changed by that raw call.
It cannot prove a non-null pointer is valid, sufficiently sized, aligned,
live or remotely mapped. Those storage obligations remain with the caller.

Hexagon analysis, not deployment
--------------------------------

The second stage binds the actual completed CPU receipt and freshly generated
skeleton/header, then compiles Hexagon v73 objects and links an analysis DSO.
It uses Clang's resource headers, -ffreestanding/-nostdinc and four explicitly
declaration-only standard-header facades. These declarations are not an SDK,
allocator, libc implementation or a supplied DSP runtime. No host CRT or
proprietary runtime is substituted.

The link profile explicitly uses:

  -z max-page-size=4096 -z common-page-size=4096
  -z separate-loadable-segments

The validator inspects the resulting ELF rather than assuming those flags
suffice: actual LOAD segments must have 4096-byte alignment, valid extents,
offset/address congruence, disjoint page-rounded file/virtual ranges and no
writable-executable program header. The analysis link and ELF inventory reject
strong unresolved imports. All program headers, sections, dynamic
symbols, imports, relocations and dependencies are recorded. NOTE, TLS and
GNU_STACK headers are inventoried; their absence or QuRT support is not guessed.
This is a deliberate 4 KiB LOAD analysis profile, not demonstrated QuRT loader
compatibility. Any unresolved strong runtime import remains a blocker; even
zero imports does not establish the loader ABI or execution correctness.

The actual device ISA, permitted unsigned user protection domain, firmware,
remote process shell, QuRT/FastRPC loader ABI, physical transport and remote
results remain unknown/unqualified. Neither the client nor the DSP DSO is run.
Do not load, install or copy these artifacts to a device on the strength of
these software checks. There is no hardware, NPU, HTP, performance, full-parity
or production-installability claim.

Results and failure evidence
----------------------------

The top-level RESULT.json refers to cpu/RESULT.json and hexagon/RESULT.json.
Keep those receipts together with logs, command records, generated sources,
ELF inventories and INPUT-BEFORE/AFTER/DIFF records. A failure remains a failure
even when some useful artifacts were produced. Preserve partial output and
choose a different fresh output directory for a separately authorized retry.

A successful status is explicitly diagnostics-await-review and runtime-
unqualified. It is not an install approval. Manifest checks cannot authenticate
their own source, and sampled guards cannot promise exact resource quotas.

Licences and notices
--------------------

This collection does not relicense its components. Read NOTICE.txt and the
individual source notices. Authored native/tools code uses BSD-3-Clause;
upstream QAIC uses BSD-3-Clause-Clear; FastRPC retains mixed BSD-3-Clause and
BSD-3-Clause-Clear notices plus embedded Linux Foundation and Troy D. Hanson
notices. The public UAPI header is marked GPL-2.0 WITH Linux-syscall-note.
The corresponding texts are included under LICENSES/. Preserve them when
redistributing source or any later binary distribution as their terms require.
No patent-rights or proprietary runtime grant is implied by this source kit.
