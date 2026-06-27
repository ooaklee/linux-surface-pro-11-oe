# Johan G. qcom-x1e 7.1.1 build compatibility patches

These patches are for building Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.1.1
tag with this repository's Docker kernel builder.

The upstream tag already carries the Surface Pro 11 Wi-Fi `disable-rfkill`
kernel and Denali DTB changes, so this directory only carries build policy
compatibility patches needed by Ubuntu's `check-config` step.
