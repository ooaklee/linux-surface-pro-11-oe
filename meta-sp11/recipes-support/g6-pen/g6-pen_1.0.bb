SUMMARY = "Surface G6 HEAT userspace pen processor"
DESCRIPTION = "Versioned HEAT record consumer, cycle tracker, replay tool, and uinput pen daemon"
HOMEPAGE = "https://github.com/ooaklee/linux-surface-pro-11-oe"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=e948d3d7d3912672e084e1a003c2f167"

inherit systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/../../../userspace/g6-pen:"

SRC_URI = " \
    file://LICENSE \
    file://Makefile \
    file://include/g6_heat_abi.h \
    file://include/g6_pen.h \
    file://src/g6_heat.c \
    file://src/g6_processor.c \
    file://src/g6_uinput.c \
    file://src/main.c \
    file://packaging/g6-pen.conf \
    file://packaging/g6-pen.service \
    file://README.md \
"

S = "${UNPACKDIR}"

do_compile() {
    oe_runmake g6-pen
}

do_install() {
    oe_runmake install DESTDIR=${D} sbindir=${sbindir}
    install -d ${D}${sysconfdir}
    install -m 0644 ${S}/packaging/g6-pen.conf ${D}${sysconfdir}/g6-pen.conf
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/packaging/g6-pen.service \
        ${D}${systemd_system_unitdir}/g6-pen.service
    install -d ${D}${docdir}/g6-pen
    install -m 0644 ${S}/README.md ${D}${docdir}/g6-pen/README.md
}

SYSTEMD_SERVICE:${PN} = "g6-pen.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"
RCONFLICTS:${PN} += "iptsd-sp11"

FILES:${PN} += "${systemd_system_unitdir}/g6-pen.service"
