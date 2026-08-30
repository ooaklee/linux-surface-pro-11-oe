package ubuntu

import "fmt"

// grubConfig renders the direct-GRUB menu for both supported Surface Pro 11
// device-tree variants while binding every entry to the supplied kernel ABI.
func grubConfig(abi string) string {
	return fmt.Sprintf(`set timeout=30
set default=0

insmod part_gpt
insmod iso9660
insmod search
insmod search_fs_file
insmod smbios
insmod regexp
insmod fdt

search --no-floppy --file --set=iso_root /casper/vmlinuz
set root=$iso_root

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

set cmdline=
smbios --type 4 --get-string 5 --set proc_version
regexp "Snapdragon.*" "$proc_version"
if [ $? = 0 ]; then
  if [ $lockdown != "y" ]; then
    cutmem 0x8800000000 0x8fffffffff
  fi
  set cmdline="clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0 soundwire_qcom.sp11_feedback_active_offset2_zero=1"
fi

menuentry "Ubuntu for Surface Pro 11 X1E/OLED (%s)" {
    set gfxpayload=keep
    linux /casper/vmlinuz $cmdline modprobe.blacklist=qcom_q6v5_pas --- quiet splash console=tty0
    devicetree /sp11/dtb/x1e80100-microsoft-denali-oled.dtb
    initrd /casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 X1P/LCD (%s, hardware qualification pending)" {
    set gfxpayload=keep
    linux /casper/vmlinuz $cmdline modprobe.blacklist=qcom_q6v5_pas --- quiet splash console=tty0
    devicetree /sp11/dtb/x1p64100-microsoft-denali.dtb
    initrd /casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 X1E/OLED (allow aDSP)" {
    set gfxpayload=keep
    linux /casper/vmlinuz $cmdline --- quiet splash console=tty0
    devicetree /sp11/dtb/x1e80100-microsoft-denali-oled.dtb
    initrd /casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 X1E/OLED (text diagnostics)" {
    set gfxpayload=keep
    linux /casper/vmlinuz $cmdline modprobe.blacklist=qcom_q6v5_pas debug systemd.unit=multi-user.target plymouth.enable=0 --- console=tty0
    devicetree /sp11/dtb/x1e80100-microsoft-denali-oled.dtb
    initrd /casper/initrd
}

menuentry 'Boot from next volume' {
    exit 1
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
`, abi, abi)
}
