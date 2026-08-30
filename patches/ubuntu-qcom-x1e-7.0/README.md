# Archived Ubuntu qcom-x1e Wi-Fi rfkill patches

> [!IMPORTANT]
> This directory records an early Surface Pro 11 bring-up patch set. It is not
> a current build input and must not be applied to a maintained kernel.

The two patches taught `ath12k` a `disable-rfkill` device-tree property and set
it on the Microsoft Denali WCN7850 node. That experiment helped establish the
kernel-side Wi-Fi path now carried by the maintained custom source branch.

Use `linux-armer kernel build` for the reviewed maintained ref and
`linux-armer doctor hardware wifi` for bounded live evidence. Distribution
firmware owns current board data; the CLI does not inject this archived patch
set or install a Wi-Fi board-file workaround.
