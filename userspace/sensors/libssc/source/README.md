# libssc

`libssc` is a library to <b>expose the sensors</b> managed by the <b>Qualcomm Sensor Core</b>
found in many Qualcomm System-on-Chips (SoCs) from 2018 and onwards. 

Qualcomm SoCs feature a Sensor Lower Power Island (SLPI)
to offload sensors to a dedicated <b>Digital Signal Processor (DSP)</b>
for <b>optimizing power consumption</b> and <b>reducing the tasks of the main CPU</b>.
This way, the main CPU may enter full suspend while the DSP can detect proximity
from the proximity sensor and wake up the main CPU.
<b>Direct access to the sensors is prohibited</b> by the hypervisor,
thus the only way to access sensors on these SoCs is by talking
to the DSP managing these sensors.
Libssc performs this task and <b>exposes the sensors as a GLib-based library</b>
which allows seamless integration with the existing Linux ecosystem. 

_Qualcomm, Sensor Low Power Island (SLPI), and Qualcomm Sensor Core are registed trademarks
of QUALCOMM Incorporated. Any rights therein are reserved to QUALCOMM Incorporated.
Any use by the libssc project is for referential purposes only and does not indicate any sponsorship,
endorsement or affiliation between QUALCOMM Incorporated and the libssc project._

## Documentation

General information about libssc, documentation, and other information can be found at
[https://libssc.dylanvanassche.be](https://libssc.dylanvanassche.be).

## Building

`libssc` uses the Meson build system with a minimal list of external dependencies:

- `libqmi-dev >=1.33.4`
- `glib-dev >= 2.56`
- `protobuf-c-dev`
- `gobject-introspection-dev`

`libssc` tests requires an additional dependency to compile the ProtoBuf messages for simulating the DSP QMI responses:

- `py3-gobject3-dev`
- `protobuf-dev`
- `py3-protobuf`
- `qrtr-libs`

```
meson setup _build
meson compile -C _build
```

Tests can be executed with:

```
meson test -C _build
```

## Linking against libssc

Use `pkg-config` in your favorite build system to link against `libssc`.
The library is called `libssc`, in Meson it looks like this:

```
libssc_dep = dependency('libssc')
```

## Lockdown

Systemd features a lockdown feature to reduce access to resources for services.
If `libssc` is used in a service such as `iio-sensor-proxy`, make sure access to the address family `AF_QIPCRTR`
otherwise access to the QRTR bus is prohibited.

## Tests

Libssc has tests with and without the SSC mocking server to verify also the behavior
of libssc when the QMI service is not present.

## License

Available under the [GPLv3 license](./LICENSE).<br>
Copyright (c) by libssc Authors (2022-2026)
