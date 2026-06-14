param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop\sp11-linux-checks"
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportDir = Join-Path $OutputRoot "report-$timestamp"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

function Write-Section {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $txtPath = Join-Path $reportDir "$safeName.txt"
    $jsonPath = Join-Path $reportDir "$safeName.json"

    "## $Name" | Out-File -FilePath $txtPath -Encoding UTF8
    try {
        $result = & $Command
        $result | Format-List * | Out-File -FilePath $txtPath -Encoding UTF8 -Append
        $result | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding UTF8
    } catch {
        "ERROR: $($_.Exception.Message)" | Out-File -FilePath $txtPath -Encoding UTF8 -Append
    }
}

function Write-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandLine
    )

    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $txtPath = Join-Path $reportDir "$safeName.txt"

    "## $Name" | Out-File -FilePath $txtPath -Encoding UTF8
    "Command: $CommandLine" | Out-File -FilePath $txtPath -Encoding UTF8 -Append
    "" | Out-File -FilePath $txtPath -Encoding UTF8 -Append
    try {
        cmd.exe /c $CommandLine 2>&1 | Out-File -FilePath $txtPath -Encoding UTF8 -Append
    } catch {
        "ERROR: $($_.Exception.Message)" | Out-File -FilePath $txtPath -Encoding UTF8 -Append
    }
}

Start-Transcript -Path (Join-Path $reportDir "transcript.txt") -Force | Out-Null

@"
This report may contain hardware addresses, IP configuration, device serials,
firmware paths, boot entries, and BitLocker status. Redact hardware addresses,
UUIDs, serials, and local network details before sharing publicly.
"@ | Out-File -FilePath (Join-Path $reportDir "privacy-note.txt") -Encoding UTF8

Write-Section "computer-system" { Get-CimInstance Win32_ComputerSystem }
Write-Section "computer-system-product" { Get-CimInstance Win32_ComputerSystemProduct }
Write-Section "bios" { Get-CimInstance Win32_BIOS }
Write-Section "baseboard" { Get-CimInstance Win32_BaseBoard }
Write-Section "operating-system" { Get-CimInstance Win32_OperatingSystem }
Write-Section "processor" { Get-CimInstance Win32_Processor }
Write-Section "secure-boot" { [pscustomobject]@{ SecureBootEnabled = Confirm-SecureBootUEFI } }
Write-Section "bitlocker-volume" { Get-BitLockerVolume }
Write-Section "physical-disk" { Get-PhysicalDisk | Sort-Object FriendlyName }
Write-Section "disk" { Get-Disk | Sort-Object Number }
Write-Section "partition" { Get-Partition | Sort-Object DiskNumber, PartitionNumber }
Write-Section "volume" { Get-Volume | Sort-Object DriveLetter }
Write-Section "pnp-present" { Get-PnpDevice -PresentOnly | Sort-Object Class, FriendlyName }
Write-Section "pnp-usb" { Get-PnpDevice -PresentOnly | Where-Object { $_.Class -match 'USB|Bluetooth|Net|HIDClass|Keyboard|Mouse|Surface' } | Sort-Object Class, FriendlyName }
Write-Section "net-adapters" { Get-NetAdapter -IncludeHidden | Sort-Object Name }
Write-Section "net-adapter-hardware-addresses" {
    Get-NetAdapter -IncludeHidden |
        Sort-Object Name |
        Select-Object Name, InterfaceDescription, Status, MacAddress, PermanentAddress, LinkLayerAddress
}
Write-Section "net-ip" { Get-NetIPConfiguration }
Write-Section "bluetooth-pnp-devices" {
    Get-PnpDevice -PresentOnly |
        Where-Object { $_.Class -match 'Bluetooth' -or $_.FriendlyName -match 'Bluetooth|WCN|Qualcomm|FastConnect' } |
        Sort-Object Class, FriendlyName
}
Write-Section "bluetooth-pnp-properties" {
    Get-PnpDevice -PresentOnly |
        Where-Object { $_.Class -match 'Bluetooth' -or $_.FriendlyName -match 'Bluetooth|WCN|Qualcomm|FastConnect' } |
        ForEach-Object {
            $device = $_
            Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction SilentlyContinue |
                Select-Object @{Name = "Device"; Expression = { $device.FriendlyName } },
                              @{Name = "InstanceId"; Expression = { $device.InstanceId } },
                              KeyName, Type, Data
        }
}
Write-Section "firmware-files" {
    $roots = @(
        "$env:WINDIR\System32",
        "$env:WINDIR\System32\DriverStore\FileRepository"
    )
    $names = @(
        "qcdxkmsuc8380.mbn",
        "adsp_dtbs.elf",
        "qcadsp8380.mbn",
        "cdsp_dtbs.elf",
        "qccdsp8380.mbn",
        "adspr.jsn",
        "adsps.jsn",
        "adspua.jsn",
        "battmgr.jsn",
        "cdspr.jsn",
        "qcdxkmsucpurwa.mbn"
    )
    foreach ($root in $roots) {
        if (Test-Path $root) {
            foreach ($name in $names) {
                Get-ChildItem -Path $root -Filter $name -Recurse -ErrorAction SilentlyContinue |
                    Select-Object FullName, Length, LastWriteTime
            }
        }
    }
}

Write-Command "systeminfo" "systeminfo"
Write-Command "manage-bde-status" "manage-bde -status"
Write-Command "bcdedit-firmware" "bcdedit /enum firmware"
Write-Command "bcdedit-all" "bcdedit /enum all"
Write-Command "powercfg-a" "powercfg /a"
Write-Command "powercfg-devicequery-wake" "powercfg /devicequery wake_armed"
Write-Command "pnputil-drivers" "pnputil /enum-drivers"
Write-Command "pnputil-devices-connected" "pnputil /enum-devices /connected"

$batteryReport = Join-Path $reportDir "battery-report.html"
Write-Command "battery-report" "powercfg /batteryreport /output `"$batteryReport`""

$msinfoPath = Join-Path $reportDir "msinfo32.txt"
Start-Process -FilePath "msinfo32.exe" -ArgumentList "/report `"$msinfoPath`"" -Wait -WindowStyle Hidden

Stop-Transcript | Out-Null

$zipPath = Join-Path $OutputRoot "sp11-linux-checks-$timestamp.zip"
Compress-Archive -Path $reportDir -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Surface Pro 11 diagnostics complete."
Write-Host "Privacy note: report may contain hardware addresses, UUIDs, serials, and network details."
Write-Host "Report directory: $reportDir"
Write-Host "Zip report:       $zipPath"
