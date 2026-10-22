# Source-build dependencies only; no host source, firmware or target payload.
FROM docker.io/library/buildpack-deps@sha256:c975ce4edd436f5e102ece6f1c2e9416e0a3ce4b5f8477a0a371238828182132 AS public-ca
FROM docker.io/library/ubuntu@sha256:18b33ff3829707f31ada654a963b9ee35f2e6f0241b964bd17a22a9b330cb63d
ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C
WORKDIR /opt/sp11-compute-toolchain
# The minimal Ubuntu base has no CA bundle. Copy only the public trust store
# from an immutable official Ubuntu-based image; never disable TLS verification.
COPY --from=public-ca /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources
# The timestamp is in the sole configured archive URL for both operations.
# ports.ubuntu.com lacks APT's snapshot mapping; do not rely on auto detection.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential autoconf automake libtool pkg-config libyaml-dev libbsd-dev \
       clang-19 lld-19 llvm-19 ghc cabal-install libghc-syb-dev ca-certificates \
       git file python3 patch
RUN dpkg-query -W '-f=${binary:Package}\t${Version}\t${Architecture}\n' > packages.tsv \
    && ghc --numeric-version > ghc-version.txt \
    && cabal --numeric-version > cabal-version.txt \
    && clang-19 --version > clang-version.txt \
    && ld.lld-19 --version > lld-version.txt \
    && ghc-pkg list > ghc-packages.txt
USER 65532:65532
ENTRYPOINT []
CMD ["/usr/bin/true"]
