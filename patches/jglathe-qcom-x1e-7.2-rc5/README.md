# Archived Johan G. qcom-x1e 7.2-rc5 build-compatibility patches

> [!IMPORTANT]
> This directory is historical evidence for the `7.2-rc5-jg-0` build. It is
> not a current `linux-armer` input or annotation-regeneration procedure.

The upstream branch already carried the Surface Pro 11 Wi-Fi, Denali and
stubble-path changes. This directory recorded only the Ubuntu `check-config`
compatibility state observed during that release experiment.

Configuration and annotation maintenance now belongs in the maintained kernel
source repository. Source maintainers must use the exact branch's Debian
tooling and declared compiler probes, review the generated annotation diff and
commit it with the source change. The OE CLI builds a reviewed ref and records
its immutable provenance; it does not generate or write source patches.
