# SOP: Generate a Surface Pro 11 Service Report

Use this procedure to collect a Windows-side diagnostic bundle from a Surface
Pro 11 and turn it into a concise hardware report like
[`docs/hardware-report-20260613.md`](../hardware-report-20260613.md).

## Purpose

The service report captures the hardware, firmware, storage, boot, and driver
state needed to build or debug Ubuntu boot media for Surface Pro 11 devices.
It is especially useful before changing partitions, disabling Secure Boot, or
testing a new USB image.

## Prerequisites

- A Surface Pro 11 booted into Windows.
- PowerShell. An Administrator PowerShell is recommended.
- The repository's diagnostic collector:
  `tools/collect-sp11-windows-diagnostics.ps1`.

Running without Administrator rights is allowed, but some sections may fail or
be incomplete. BitLocker and Secure Boot checks are the most likely to need
elevated permissions.

## Procedure

1. Copy `tools/collect-sp11-windows-diagnostics.ps1` to the Surface Pro 11.

2. Open PowerShell on the Surface Pro 11.

3. Change to the directory containing the copied script.

4. Run the collector:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-diagnostics.ps1
```

To place the output somewhere other than the Desktop, pass `-OutputRoot`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-diagnostics.ps1 -OutputRoot "C:\sp11-linux-checks"
```

5. Wait for the script to finish. `msinfo32` and DriverStore searches can take
   a few minutes.

6. Confirm that the final output includes both paths:

```text
Surface Pro 11 diagnostics complete.
Report directory: <output-root>\report-<timestamp>
Zip report:       <output-root>\sp11-linux-checks-<timestamp>.zip
```

7. Copy the generated `.zip` file to the workstation used for bring-up
   analysis.

## Expected Output

The collector writes a timestamped report directory and a compressed zip. The
report contains text and JSON files for:

- system model, SKU, BIOS, baseboard, OS, and CPU,
- Secure Boot and BitLocker state,
- physical disks, partitions, and volumes,
- present PnP devices, with focused USB/Bluetooth/network/HID/Surface devices,
- network adapters and IP configuration,
- Surface Pro 11 firmware files found in `System32` and the DriverStore,
- `systeminfo`, `bcdedit`, `powercfg`, `pnputil`, battery report, and
  `msinfo32` output.

## Create the Markdown Hardware Report

1. Create a new dated report:

```bash
cp docs/hardware-report-20260613.md docs/hardware-report-YYYYMMDD.md
```

2. Replace the existing values with the new service-report values.

3. Keep the Markdown summary focused on:

- device identity: manufacturer, model, SKU, product version, UUID, BIOS, OS,
  build, CPU,
- Secure Boot state, or note when the collected value is blank,
- storage: physical disk, bus type, partition style, size, volumes,
- firmware observations: Qualcomm display, aDSP, cDSP, and JSON firmware files,
- relevant devices: Wi-Fi/Bluetooth, Surface HID, USB controllers, Surface
  management clients.

4. Do not paste the full raw report into Markdown. Summarize the fields needed
   for Linux bring-up and keep the zip as a local artifact.

## Privacy and Safety

The raw service report can contain device identifiers, serial-like values,
network configuration, firmware paths, and boot configuration. Do not commit
raw report directories or zip files.

Before committing the Markdown summary, check that:

- no raw `.zip`, `.json`, `.txt`, `.html`, or `msinfo32` dump was added,
- no local workstation paths are included,
- no personal account names, network addresses, or secrets are present,
- firmware blobs are not copied into git.

## Troubleshooting

If `Get-BitLockerVolume` fails, rerun PowerShell as Administrator.

If `Confirm-SecureBootUEFI` is blank or errors, manually confirm Secure Boot in
Surface UEFI before boot testing.

If the script cannot be run because of execution policy, use the
`-ExecutionPolicy Bypass` command shown above. This changes policy only for
that process.

If the report takes a long time, wait for `msinfo32` to finish. The collector
does not complete until it has created both the report directory and zip file.
