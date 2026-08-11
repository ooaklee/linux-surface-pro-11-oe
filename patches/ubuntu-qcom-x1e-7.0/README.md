# Ubuntu qcom-x1e Wi-Fi rfkill patches

These patches are for the Ubuntu Snapdragon X `qcom-x1e` kernel source used by
the Surface Pro 11 bring-up.

They carry the two-part Wi-Fi rfkill fix from Dale Whinham's Surface Pro 11
kernel work:

1. `ath12k` learns a boolean `disable-rfkill` devicetree property.
2. The Microsoft Denali WCN7850 `wifi@0` node sets `disable-rfkill;`.

Pass `--patch-dir patches/ubuntu-qcom-x1e-7.0` to
`scripts/build-sp11-qcom-x1e-kernel.sh` to apply them to the Ubuntu source
package recorded by the running qcom-x1e kernel packages or, as a fallback, to
the public Ubuntu concept kernel git branch. Omitting both patch options builds
the selected source without local patches.

Do not commit generated kernel source trees, `.deb` files, or installed kernel
artifacts.
