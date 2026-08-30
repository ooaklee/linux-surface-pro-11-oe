SUMMARY = "Surface Pro 11 IPTS stylus daemon"
DESCRIPTION = "Pinned iptsd stylus processing and SP11 HIDRAW lifecycle integration"
HOMEPAGE = "https://github.com/linux-surface/iptsd"
LICENSE = "GPL-2.0-or-later & MIT"
LIC_FILES_CHKSUM = " \
    file://LICENSE;md5=b234ee4d69f5fce4486a80fdaf4a4263 \
    file://${UNPACKDIR}/LICENSE.integration;md5=ce6cbf9ccd2bf8dedf225c9cf23eb76f \
"

FILESEXTRAPATHS:prepend := "${THISDIR}/../../../userspace/iptsd-sp11:"

SRC_URI = " \
    git://github.com/linux-surface/iptsd.git;protocol=https;nobranch=1 \
    file://LICENSE.integration \
    file://config/surface-pro-11-0c80.conf \
    file://config/surface-pro-11-0c83.conf \
    file://packaging/70-sp11-iptsd.rules.in \
    file://packaging/sp11-iptsd@.service.in \
    file://packaging/sp11-iptsd-restart.in \
    file://README.md \
"
SRCREV = "a83bc1232f7096f8b33b50fdbda249cd640de670"
S = "${WORKDIR}/git"

DEPENDS = " \
    cli11 \
    cmake-native \
    fmt \
    libeigen \
    libinih \
    microsoft-gsl \
    spdlog \
"

inherit features_check meson pkgconfig systemd

REQUIRED_DISTRO_FEATURES = "systemd"

EXTRA_OEMESON = " \
    -Ddebug_tools=[] \
    -Dservice_manager=[] \
    -Dsample_config=false \
    -Dforce_access_checks=true \
    -Dwerror=false \
    -Db_lto=false \
"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${B}/src/iptsd ${D}${libexecdir}/sp11-iptsd
    install -m 0755 ${B}/src/iptsd-check-device \
        ${D}${libexecdir}/sp11-iptsd-check-device

    install -d ${D}${datadir}/iptsd
    install -m 0644 ${UNPACKDIR}/config/surface-pro-11-0c80.conf \
        ${D}${datadir}/iptsd/
    install -m 0644 ${UNPACKDIR}/config/surface-pro-11-0c83.conf \
        ${D}${datadir}/iptsd/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/packaging/sp11-iptsd@.service.in \
        ${D}${systemd_system_unitdir}/sp11-iptsd@.service

    install -d ${D}${nonarch_base_libdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/packaging/70-sp11-iptsd.rules.in \
        ${D}${nonarch_base_libdir}/udev/rules.d/70-sp11-iptsd.rules

    install -d ${D}${systemd_unitdir}/system-sleep
    install -m 0755 ${UNPACKDIR}/packaging/sp11-iptsd-restart.in \
        ${D}${systemd_unitdir}/system-sleep/sp11-iptsd-restart

    sed -i \
        -e 's,@IPTSD@,${libexecdir}/sp11-iptsd,g' \
        -e 's,@CHECKER@,${libexecdir}/sp11-iptsd-check-device,g' \
        -e 's,@SYSTEMCTL@,${bindir}/systemctl,g' \
        -e 's,@SYSTEMD_ESCAPE@,${bindir}/systemd-escape,g' \
        ${D}${systemd_system_unitdir}/sp11-iptsd@.service \
        ${D}${nonarch_base_libdir}/udev/rules.d/70-sp11-iptsd.rules \
        ${D}${systemd_unitdir}/system-sleep/sp11-iptsd-restart
}

SYSTEMD_SERVICE:${PN} = "sp11-iptsd@.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

RRECOMMENDS:${PN} += "kernel-module-uinput"
RDEPENDS:${PN} += "systemd-extra-utils"
RCONFLICTS:${PN} += "g6-pen iptsd"
RREPLACES:${PN} += "g6-pen"

FILES:${PN} += " \
    ${datadir}/iptsd \
    ${nonarch_base_libdir}/udev/rules.d/70-sp11-iptsd.rules \
    ${systemd_system_unitdir}/sp11-iptsd@.service \
    ${systemd_unitdir}/system-sleep/sp11-iptsd-restart \
"
