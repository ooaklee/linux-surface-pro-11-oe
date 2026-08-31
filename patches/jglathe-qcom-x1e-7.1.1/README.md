# Johan G. qcom-x1e 7.1.1 build compatibility patches

> [!IMPORTANT]
> **Archived compatibility evidence — not a current build input.**
> Local patch injection and the repository script that consumed this directory
> are retired. Do not apply these files to a current kernel build.

These patches were used to build Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.1.1
tag with an earlier repository Docker workflow.

The upstream tag already carries the Surface Pro 11 Wi-Fi `disable-rfkill`
kernel and Denali DTB changes, so this directory only carries build policy
compatibility patches needed by Ubuntu's `check-config` step.

Use `lexr kernel build` for a current build. The selected reviewed
kernel ref now owns its source configuration and annotations; the CLI does not
silently inject this archived directory.
