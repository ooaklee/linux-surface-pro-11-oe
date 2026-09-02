FILESEXTRAPATHS:prepend := "${THISDIR}/../../../userspace/power-profiles-daemon-sp11:"

# Make the native-class integration a distinct, upgradeable package revision.
PR:append = ".sp11.1"

SRC_URI += " \
    file://0001-platform-profile-consume-single-class-device.patch \
    file://SP11-NATIVE-CLASS \
"

do_install:append() {
    install -d ${D}${docdir}/${BPN}
    install -m 0644 ${UNPACKDIR}/SP11-NATIVE-CLASS \
        ${D}${docdir}/${BPN}/SP11-NATIVE-CLASS
}
