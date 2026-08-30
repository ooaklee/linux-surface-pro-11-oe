<#
.SYNOPSIS
Collects a private Surface Pro 11 Windows hand-off for linux-armer.

.DESCRIPTION
Creates the strict version 1 Windows hand-off directory consumed by
`linux-armer handoff import`. The collector can include the complete audited
eleven-file platform firmware set, the same-device Bluetooth public address,
or both. It never exports Windows Wi-Fi firmware.

The complete hand-off is private, device-bound material. It contains
proprietary firmware, salted hardware bindings, Windows driver provenance and,
when available, a Bluetooth public address. Keep it on trusted storage, do not
publish it, and purge it when it is no longer required.

.PARAMETER OutputDirectory
Specifies a new directory to create. The parent directory must already exist,
must not be a reparse point, and the destination must not already exist. The
collector never overwrites or merges an existing directory.

.PARAMETER Components
Chooses Both, PlatformFirmware or Bluetooth. A deliberately excluded section
is recorded as not-requested. A requested but unavailable section is recorded
as unavailable only when the other section can still make a valid hand-off.

.PARAMETER UseBTHPORTRegistry
Explicitly confirms that the sole local BTHPORT controller-address key has been
checked against the physical Bluetooth device. Use this only when the preferred
Bluetooth network-adapter PermanentAddress is unavailable. The raw adapter
instance identifier is never written to disk or displayed.

.PARAMETER SelfTest
Runs the pinned device and Bluetooth binding vectors without collecting device
data. This parameter set does not require Windows or administrator privileges.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -OutputDirectory E:\sp11-handoff

Collects both supported sections into a new directory.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -OutputDirectory E:\sp11-handoff -Components PlatformFirmware

Collects only the complete platform firmware set and records Bluetooth as not
requested.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -SelfTest

Checks that this script's domain-separated hash implementation matches the Go
contract's pinned vectors.
#>
[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Collect')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter(ParameterSetName = 'Collect')]
    [ValidateSet('Both', 'PlatformFirmware', 'Bluetooth')]
    [string]$Components = 'Both',

    [Parameter(ParameterSetName = 'Collect')]
    [switch]$UseBTHPORTRegistry,

    [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:CollectorName = 'collect-sp11-windows-handoff.ps1'
$script:CollectorVersion = '1.0.0'
$script:ManifestFilename = 'linux-armer-windows-handoff.json'
$script:DeviceBindingDomain = 'linux-armer.windows-handoff/device-binding/v1'
$script:BluetoothAdapterBindingDomain = 'linux-armer.windows-handoff/bluetooth-adapter-binding/v1'
$script:MaximumManifestBytes = 1MB
$script:MaximumFirmwareFileBytes = 512MB
$script:MaximumFirmwareTotalBytes = 1GB

<#
.SYNOPSIS
Returns lowercase hexadecimal for an immutable byte sequence.

.DESCRIPTION
Formats bytes without separators using invariant lowercase hexadecimal. This
is used for salts and SHA-256 values in the strict hand-off contract.
#>
function ConvertTo-LowerHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return ([System.BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

<#
.SYNOPSIS
Decodes canonical lowercase hexadecimal into bytes.

.DESCRIPTION
Rejects odd-width, uppercase and non-hexadecimal input before decoding. The
function is used by the pinned self-test and does not accept loose formatting.
#>
function ConvertFrom-LowerHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (($Value.Length % 2) -ne 0 -or $Value -cne $Value.ToLowerInvariant() -or $Value -notmatch '^[0-9a-f]+$') {
        throw 'Hexadecimal input must be canonical lowercase text with an even width.'
    }

    $bytes = New-Object byte[] ($Value.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Value.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

<#
.SYNOPSIS
Creates a fresh cryptographically random 32-byte binding salt.

.DESCRIPTION
Uses the operating system cryptographic random-number generator for every
collection and rejects the vanishingly unlikely all-zero result.
#>
function New-BindingSalt {
    [CmdletBinding()]
    param()

    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 32
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }

    $hasNonZeroByte = $false
    foreach ($item in $bytes) {
        if ($item -ne 0) {
            $hasNonZeroByte = $true
            break
        }
    }
    if (-not $hasNonZeroByte) {
        [Array]::Clear($bytes, 0, $bytes.Length)
        throw 'The cryptographic random-number generator returned an invalid all-zero salt.'
    }
    return ,$bytes
}

<#
.SYNOPSIS
Derives a domain-separated private hardware binding.

.DESCRIPTION
Computes SHA-256 over the printable ASCII domain, one NUL separator, the raw
32-byte salt and the canonical printable ASCII value, in that exact order. It
matches the Go hand-off contract and never logs the private derivation input.
#>
function Get-DomainSeparatedBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [byte[]]$Salt,

        [Parameter(Mandatory = $true)]
        [string]$CanonicalValue
    )

    if ($Salt.Length -ne 32) {
        throw 'A hand-off binding requires exactly 32 salt bytes.'
    }
    if ($Domain -notmatch '^[\x21-\x7E]+$' -or $CanonicalValue -notmatch '^[\x21-\x7E]+$') {
        throw 'A hand-off binding accepts printable ASCII domain and value text only.'
    }

    $ascii = [System.Text.Encoding]::ASCII
    $domainBytes = $ascii.GetBytes($Domain)
    $valueBytes = $ascii.GetBytes($CanonicalValue)
    $inputBytes = New-Object byte[] ($domainBytes.Length + 1 + $Salt.Length + $valueBytes.Length)
    [Buffer]::BlockCopy($domainBytes, 0, $inputBytes, 0, $domainBytes.Length)
    $saltOffset = $domainBytes.Length + 1
    [Buffer]::BlockCopy($Salt, 0, $inputBytes, $saltOffset, $Salt.Length)
    [Buffer]::BlockCopy($valueBytes, 0, $inputBytes, $saltOffset + $Salt.Length, $valueBytes.Length)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($inputBytes)
        return ConvertTo-LowerHex -Bytes $digest
    } finally {
        $sha256.Dispose()
        [Array]::Clear($inputBytes, 0, $inputBytes.Length)
        [Array]::Clear($valueBytes, 0, $valueBytes.Length)
    }
}

<#
.SYNOPSIS
Runs the contract's pinned derivation vectors.

.DESCRIPTION
Proves that the PowerShell byte order, NUL separator, salt decoding and ASCII
normalisation produce the exact values pinned by the Go implementation.
#>
function Assert-BindingSelfTest {
    [CmdletBinding()]
    param()

    $salt = ConvertFrom-LowerHex -Value '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    try {
        $device = Get-DomainSeparatedBinding -Domain $script:DeviceBindingDomain -Salt $salt -CanonicalValue '12345678-1234-5678-9abc-def012345678'
        if ($device -cne '094fb62588717c3c117b6a5ce3ada6a3d2c247c306239cd0f62f432ea688f600') {
            throw 'The device-binding self-test did not match the Go contract.'
        }

        $adapter = Get-DomainSeparatedBinding -Domain $script:BluetoothAdapterBindingDomain -Salt $salt -CanonicalValue 'BTH\MS_BTHPAN\7&12345678&0&2'
        if ($adapter -cne '1c160571108944ea6d3bd4f45f65133cea74a9a4097d3f75eb315ac138a99f70') {
            throw 'The Bluetooth adapter-binding self-test did not match the Go contract.'
        }
    } finally {
        [Array]::Clear($salt, 0, $salt.Length)
    }
}

<#
.SYNOPSIS
Runs portable file and encoding checks used by the collector.

.DESCRIPTION
Exercises BOM-less UTF-8 creation, bounded SHA-256 reads and verified file
copying in a temporary directory. It gives -SelfTest useful coverage on a host
that does not provide the Windows device cmdlets.
#>
function Assert-PortableFileSelfTest {
    [CmdletBinding()]
    param()

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('linux-armer-handoff-self-test-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($temporaryRoot)
    try {
        $sourcePath = Join-Path $temporaryRoot 'source.bin'
        $copyPath = Join-Path $temporaryRoot 'copy.bin'
        $textPath = Join-Path $temporaryRoot 'manifest.json'
        [System.IO.File]::WriteAllBytes($sourcePath, [byte[]]@(0, 1, 2, 3, 254, 255))
        $copied = Copy-VerifiedFirmwareFile -SourcePath $sourcePath -DestinationPath $copyPath
        if ($copied.Size -ne 6 -or $copied.SHA256 -cne '7ea646958715ed687aa9ac2f5d785feb1a93411f4f25fdd6c7fcc6ab07fdf0e3') {
            throw 'The verified file-copy self-test did not match its pinned bytes.'
        }

        Write-NewUTF8File -Path $textPath -Content "{}`n"
        $bytes = [System.IO.File]::ReadAllBytes($textPath)
        if ($bytes.Length -ne 3 -or $bytes[0] -ne 0x7B -or $bytes[1] -ne 0x7D -or $bytes[2] -ne 0x0A) {
            throw 'The BOM-less UTF-8 self-test did not write the pinned bytes.'
        }
    } finally {
        if ([System.IO.Directory]::Exists($temporaryRoot)) {
            [System.IO.Directory]::Delete($temporaryRoot, $true)
        }
    }
}

<#
.SYNOPSIS
Reports whether the current process has administrator rights.

.DESCRIPTION
Uses the current Windows access token instead of parsing localised command
output, so collection can fail before attempting privileged driver queries.
#>
function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}

<#
.SYNOPSIS
Checks the Windows host and required structured cmdlets.

.DESCRIPTION
Rejects non-Windows hosts, non-administrator sessions and hosts missing the
PowerShell interfaces used for device, driver, adapter and signature evidence.
#>
function Assert-CollectorHost {
    [CmdletBinding()]
    param()

    if ($env:OS -cne 'Windows_NT') {
        throw 'Windows hand-off collection must run on Windows.'
    }
    if (-not (Test-IsAdministrator)) {
        throw 'Run the Windows hand-off collector from an Administrator PowerShell session.'
    }

    foreach ($commandName in @(
        'Get-CimInstance',
        'Get-PnpDevice',
        'Get-NetAdapter',
        'Get-WindowsDriver',
        'Get-AuthenticodeSignature'
    )) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw "Required PowerShell command is unavailable: $commandName"
        }
    }
}

<#
.SYNOPSIS
Returns the exact ordered platform firmware policy.

.DESCRIPTION
Keeps the PowerShell collector's identifiers, source filenames, payload paths
and Linux destinations byte-for-byte aligned with the Go contract. Windows
Wi-Fi firmware is intentionally absent from this closed allow-list.
#>
function Get-PlatformFirmwarePolicy {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject][ordered]@{ ID = 'gpu-main'; SourceName = 'qcdxkmsuc8380.mbn'; PayloadPath = 'payload/platform-firmware/qcdxkmsuc8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'gpu-purwa'; SourceName = 'qcdxkmsucpurwa.mbn'; PayloadPath = 'payload/platform-firmware/qcdxkmsucpurwa.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-dtb'; SourceName = 'adsp_dtbs.elf'; PayloadPath = 'payload/platform-firmware/adsp_dtbs.elf'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-main'; SourceName = 'qcadsp8380.mbn'; PayloadPath = 'payload/platform-firmware/qcadsp8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-resource'; SourceName = 'adspr.jsn'; PayloadPath = 'payload/platform-firmware/adspr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn' },
        [pscustomobject][ordered]@{ ID = 'adsp-system'; SourceName = 'adsps.jsn'; PayloadPath = 'payload/platform-firmware/adsps.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn' },
        [pscustomobject][ordered]@{ ID = 'adsp-user'; SourceName = 'adspua.jsn'; PayloadPath = 'payload/platform-firmware/adspua.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn' },
        [pscustomobject][ordered]@{ ID = 'battery-manager'; SourceName = 'battmgr.jsn'; PayloadPath = 'payload/platform-firmware/battmgr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-dtb'; SourceName = 'cdsp_dtbs.elf'; PayloadPath = 'payload/platform-firmware/cdsp_dtbs.elf'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-main'; SourceName = 'qccdsp8380.mbn'; PayloadPath = 'payload/platform-firmware/qccdsp8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-resource'; SourceName = 'cdspr.jsn'; PayloadPath = 'payload/platform-firmware/cdspr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn' }
    )
}

<#
.SYNOPSIS
Validates one canonical Windows adapter instance identifier.

.DESCRIPTION
Returns trimmed uppercase printable ASCII with at least two non-empty
backslash-separated components. Error messages never include the identifier.
#>
function ConvertTo-CanonicalAdapterInstanceID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $canonical = $Value.Trim().ToUpperInvariant()
    if ($canonical.Length -lt 3 -or $canonical.Length -gt 512 -or
        $canonical -notmatch '^[\x21-\x7E]+$' -or $canonical.Contains('/')) {
        throw 'The Windows Bluetooth adapter instance identifier is not canonical printable ASCII.'
    }
    $parts = @($canonical -split '\\')
    if ($parts.Count -lt 2 -or @($parts | Where-Object { $_.Length -eq 0 }).Count -ne 0) {
        throw 'The Windows Bluetooth adapter instance identifier lacks non-empty backslash-separated components.'
    }
    return $canonical
}

<#
.SYNOPSIS
Normalises and validates one Bluetooth public address.

.DESCRIPTION
Accepts common Windows separator forms, returns canonical uppercase
colon-separated hexadecimal, and rejects multicast, zero, broadcast and known
placeholder values without disclosing invalid input in errors.
#>
function ConvertTo-CanonicalBluetoothAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $raw = ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($raw -notmatch '^[0-9A-F]{12}$') {
        throw 'The Bluetooth public address is not twelve hexadecimal digits.'
    }
    $canonical = $raw -replace '(.{2})(?=.)', '$1:'
    $firstOctet = [Convert]::ToByte($raw.Substring(0, 2), 16)
    if (($firstOctet -band 1) -ne 0 -or $canonical -ceq '00:00:00:00:00:00' -or
        $canonical -ceq 'FF:FF:FF:FF:FF:FF' -or $canonical.StartsWith('00:00:00:00:') -or
        $canonical -ceq 'AA:AA:AA:AA:AA:AA' -or $canonical -ceq 'AA:BB:CC:DD:EE:FF') {
        throw 'The Bluetooth public address is multicast, zero, broadcast or a known placeholder.'
    }
    return $canonical
}

<#
.SYNOPSIS
Validates the current Surface Pro 11 and returns private in-memory evidence.

.DESCRIPTION
Checks the Microsoft Surface Pro 11 model, native ARM64 architecture and the
present WCN7850 PCI function. It canonicalises the SMBIOS UUID in memory but
does not print or persist the raw value.
#>
function Get-SupportedDeviceEvidence {
    [CmdletBinding()]
    param()

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = ([string]$computer.Manufacturer).Trim()
    $model = ([string]$computer.Model).Trim()
    if ($manufacturer -cne 'Microsoft Corporation' -or
        $model -notmatch '^Microsoft Surface Pro(?:,| \()? ?11th Edition\)?$') {
        throw 'This collector supports only the Microsoft Surface Pro 11.'
    }

    $arm64 = $env:PROCESSOR_ARCHITECTURE -ieq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -ieq 'ARM64'
    if (-not $arm64) {
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $arm64 = $processors.Count -gt 0 -and @($processors | Where-Object { [int]$_.Architecture -eq 12 }).Count -eq $processors.Count
    }
    if (-not $arm64) {
        throw 'This collector requires native ARM64 Windows.'
    }

    $presentDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $wifiPresent = @($presentDevices | Where-Object {
        ([string]$_.InstanceId) -match '^PCI\\VEN_17CB&DEV_1107(?:&|\\)'
    }).Count -gt 0
    if (-not $wifiPresent) {
        throw 'The required Surface Pro 11 WCN7850 PCI function 17cb:1107 is not present.'
    }

    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    $rawUUID = ([string]$product.UUID).Trim()
    try {
        $uuid = ([guid]$rawUUID).ToString('D').ToLowerInvariant()
    } catch {
        throw 'Windows did not provide a canonical SMBIOS product UUID.'
    }
    if ($uuid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $uuid -ceq '00000000-0000-0000-0000-000000000000' -or
        $uuid -ceq 'ffffffff-ffff-ffff-ffff-ffffffffffff') {
        throw 'Windows did not provide a usable SMBIOS product UUID.'
    }

    return [pscustomobject][ordered]@{
        SMBIOSUUID = $uuid
        PresentPnpDevices = $presentDevices
    }
}

<#
.SYNOPSIS
Allocates a safe same-filesystem staging directory for one new output.

.DESCRIPTION
Resolves the requested path, rejects roots, existing destinations and reparse
point parents, then creates an unpredictable sibling staging directory. The
caller can publish it with Directory.Move without crossing filesystems.
#>
function New-OutputTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedPath
    )

    $finalPath = [System.IO.Path]::GetFullPath($RequestedPath)
    $rootPath = [System.IO.Path]::GetPathRoot($finalPath)
    if ($finalPath.StartsWith('\\', [System.StringComparison]::Ordinal) -or
        (New-Object System.IO.DriveInfo($rootPath)).DriveType -eq [System.IO.DriveType]::Network) {
        throw 'The private Windows hand-off output must be on a local or removable filesystem, not a network share.'
    }
    if ($finalPath.TrimEnd('\', '/') -ieq $rootPath.TrimEnd('\', '/')) {
        throw 'The Windows hand-off output must not be a filesystem root.'
    }
    if (Test-Path -LiteralPath $finalPath) {
        throw 'The Windows hand-off output directory already exists; choose a new path.'
    }

    $parentInfo = [System.IO.Directory]::GetParent($finalPath)
    if ($null -eq $parentInfo -or -not $parentInfo.Exists) {
        throw 'The Windows hand-off output parent directory must already exist.'
    }
    $ancestor = $parentInfo
    while ($null -ne $ancestor) {
        $ancestorItem = Get-Item -LiteralPath $ancestor.FullName -Force
        if (($ancestorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The Windows hand-off output path must not pass through a reparse point.'
        }
        $ancestor = $ancestor.Parent
    }

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $stagingPath = Join-Path $parentInfo.FullName ('.linux-armer-collecting-' + [guid]::NewGuid().ToString('N'))
        if (-not (Test-Path -LiteralPath $stagingPath)) {
            [void][System.IO.Directory]::CreateDirectory($stagingPath)
            return [pscustomobject][ordered]@{
                FinalPath = $finalPath
                StagingPath = $stagingPath
            }
        }
    }
    throw 'Could not allocate an unused Windows hand-off staging directory.'
}

<#
.SYNOPSIS
Rejects reparse points between a trusted root and one selected child.

.DESCRIPTION
Resolves both paths, proves the child remains beneath the root, and inspects
the child plus every parent component. This prevents DriverStore traversal via
junctions, symbolic links or other reparse-point indirection.
#>
function Assert-NoReparsePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Child
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $childPath = [System.IO.Path]::GetFullPath($Child)
    if ($childPath -ine $rootPath -and
        -not $childPath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'A selected path escaped its trusted root.'
    }

    $currentPath = $childPath
    while ($true) {
        $item = Get-Item -LiteralPath $currentPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A selected path contains a reparse point.'
        }
        if ($currentPath -ieq $rootPath) {
            break
        }
        $parentPath = [System.IO.Path]::GetDirectoryName($currentPath)
        if ([string]::IsNullOrEmpty($parentPath) -or $parentPath -ieq $currentPath) {
            throw 'A selected path did not converge on its trusted root.'
        }
        $currentPath = $parentPath
    }
}

<#
.SYNOPSIS
Returns installed driver packages bound to present signed PnP devices.

.DESCRIPTION
Intersects present PnP identifiers, Win32 signed-driver records and structured
Get-WindowsDriver records. Only canonical published OEM INFs whose active
driver version matches their DriverStore package are retained.
#>
function Get-ActiveDriverPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PresentPnpDevices
    )

    $presentIDs = @{}
    foreach ($device in $PresentPnpDevices) {
        $instanceID = ([string]$device.InstanceId).Trim()
        if ($instanceID.Length -gt 0) {
            $presentIDs[$instanceID.ToUpperInvariant()] = $true
        }
    }

    $activeVersions = @{}
    foreach ($signedDriver in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
        $deviceID = ([string]$signedDriver.DeviceID).Trim().ToUpperInvariant()
        $publishedINF = ([string]$signedDriver.InfName).Trim().ToLowerInvariant()
        $driverVersion = ([string]$signedDriver.DriverVersion).Trim()
        if (-not $presentIDs.ContainsKey($deviceID) -or -not [bool]$signedDriver.IsSigned -or
            $publishedINF -notmatch '^oem[0-9]+\.inf$' -or $driverVersion -notmatch '^[0-9]+(?:\.[0-9]+){1,3}$') {
            continue
        }
        if (-not $activeVersions.ContainsKey($publishedINF)) {
            $activeVersions[$publishedINF] = @{}
        }
        $activeVersions[$publishedINF][$driverVersion] = $true
    }

    $fileRepository = [System.IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\DriverStore\FileRepository'))
    $packageByINF = @{}
    foreach ($driver in @(Get-WindowsDriver -Online -All -ErrorAction Stop)) {
        $publishedINF = ([string]$driver.Driver).Trim().ToLowerInvariant()
        $driverVersion = ([string]$driver.Version).Trim()
        if (-not $activeVersions.ContainsKey($publishedINF) -or
            -not $activeVersions[$publishedINF].ContainsKey($driverVersion)) {
            continue
        }

        $originalINF = [System.IO.Path]::GetFullPath(([string]$driver.OriginalFileName))
        if (-not [System.IO.File]::Exists($originalINF)) {
            throw "The active $publishedINF DriverStore INF is unavailable."
        }
        $packageRoot = [System.IO.Path]::GetDirectoryName($originalINF)
        $packageParent = [System.IO.Path]::GetDirectoryName($packageRoot)
        if ($packageParent -ine $fileRepository) {
            throw "The active $publishedINF INF is not in a direct DriverStore FileRepository package."
        }
        $packageItem = Get-Item -LiteralPath $packageRoot -Force
        if (($packageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The active $publishedINF DriverStore package is a reparse point."
        }
        Assert-NoReparsePath -Root $packageRoot -Child $originalINF

        $packageRecord = [pscustomobject][ordered]@{
            PublishedINF = $publishedINF
            DriverVersion = $driverVersion
            OriginalINF = $originalINF
            PackageRoot = $packageRoot
        }
        if ($packageByINF.ContainsKey($publishedINF)) {
            $existing = $packageByINF[$publishedINF]
            if ($existing.DriverVersion -cne $packageRecord.DriverVersion -or
                $existing.OriginalINF -ine $packageRecord.OriginalINF -or
                $existing.PackageRoot -ine $packageRecord.PackageRoot) {
                throw "Windows returned conflicting active DriverStore records for $publishedINF."
            }
        } else {
            $packageByINF[$publishedINF] = $packageRecord
        }
    }

    return @($packageByINF.Values | Sort-Object PublishedINF)
}

<#
.SYNOPSIS
Resolves and validates one package's ARM64 driver catalogue.

.DESCRIPTION
Reads only the INF Version section, prefers CatalogFile.NTARM64 over generic
catalogue declarations, requires an unambiguous package-local file, verifies
its Authenticode status and records its lowercase SHA-256 digest.
#>
function Get-PackageCatalogueEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    $declarations = @()
    $inVersionSection = $false
    foreach ($line in @(Get-Content -LiteralPath $Package.OriginalINF -ErrorAction Stop)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $inVersionSection = $matches[1] -ieq 'Version'
            continue
        }
        if (-not $inVersionSection -or $line -notmatch '^\s*(CatalogFile(?:\.[A-Za-z0-9]+)?)\s*=\s*([^;]+?)\s*(?:;.*)?$') {
            continue
        }
        $key = $matches[1].ToLowerInvariant()
        $name = $matches[2].Trim().Trim('"')
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._+~-]*\.cat$') {
            throw "The active $($Package.PublishedINF) package has a non-portable catalogue declaration."
        }
        if ($key -ceq 'catalogfile.ntarm64') {
            $priority = 0
        } elseif ($key -ceq 'catalogfile' -or $key -ceq 'catalogfile.nt') {
            $priority = 1
        } else {
            continue
        }
        $cataloguePath = Join-Path $Package.PackageRoot $name
        if ([System.IO.File]::Exists($cataloguePath)) {
            $declarations += [pscustomobject]@{ Priority = $priority; Path = [System.IO.Path]::GetFullPath($cataloguePath) }
        }
    }

    if ($declarations.Count -eq 0) {
        throw "The active $($Package.PublishedINF) package has no usable ARM64 catalogue declaration."
    }
    $bestPriority = ($declarations | Measure-Object -Property Priority -Minimum).Minimum
    $selected = @($declarations | Where-Object { $_.Priority -eq $bestPriority } | Sort-Object Path -Unique)
    if ($selected.Count -ne 1) {
        throw "The active $($Package.PublishedINF) package has ambiguous ARM64 catalogue declarations."
    }

    $catalogueItem = Get-Item -LiteralPath $selected[0].Path -Force
    Assert-NoReparsePath -Root $Package.PackageRoot -Child $catalogueItem.FullName
    $beforeSignature = Get-FileSHA256 -Path $catalogueItem.FullName
    $signature = Get-AuthenticodeSignature -LiteralPath $catalogueItem.FullName -ErrorAction Stop
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "The active $($Package.PublishedINF) package catalogue does not have a valid Windows signature."
    }
    $afterSignature = Get-FileSHA256 -Path $catalogueItem.FullName
    if ($beforeSignature.Size -ne $afterSignature.Size -or $beforeSignature.SHA256 -cne $afterSignature.SHA256) {
        throw "The active $($Package.PublishedINF) package catalogue changed during signature verification."
    }
    return [pscustomobject][ordered]@{
        SHA256 = $afterSignature.SHA256
        Signature = 'valid'
    }
}

<#
.SYNOPSIS
Converts one selected DriverStore file to its portable provenance path.

.DESCRIPTION
Requires the file to remain beneath Windows DriverStore FileRepository, checks
every path segment against the Go contract's portable vocabulary and emits a
drive-independent forward-slash path with the compiled source filename.
#>
function Get-PortableDriverStorePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$CanonicalSourceName
    )

    $repository = [System.IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\DriverStore\FileRepository')).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($SourcePath)
    $prefix = $repository + '\'
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'A selected platform firmware file escaped DriverStore FileRepository.'
    }
    if ([System.IO.Path]::GetFileName($fullPath) -ine $CanonicalSourceName) {
        throw 'A selected platform firmware filename does not match its compiled policy.'
    }

    $relative = $fullPath.Substring($prefix.Length).Replace('\', '/')
    $relativeDirectory = [System.IO.Path]::GetDirectoryName($relative.Replace('/', '\'))
    if ([string]::IsNullOrEmpty($relativeDirectory)) {
        throw 'A selected platform firmware file is not beneath a DriverStore package directory.'
    }
    $portable = 'Windows/System32/DriverStore/FileRepository/' + $relativeDirectory.Replace('\', '/') + '/' + $CanonicalSourceName
    foreach ($segment in @($portable -split '/')) {
        if ($segment -notmatch '^[A-Za-z0-9][A-Za-z0-9._+~-]*$') {
            throw 'A selected DriverStore path is not portable to the strict hand-off contract.'
        }
    }
    return $portable
}

<#
.SYNOPSIS
Hashes one regular file while denying concurrent writes and deletion.

.DESCRIPTION
Opens the file read-only with FileShare.Read, bounds its size to the contract,
and returns its positive byte length with a lowercase SHA-256 digest.
#>
function Get-FileSHA256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [long]$MaximumBytes = [long]::MaxValue
    )

    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) {
            throw 'A selected file has an invalid or excessive byte length.'
        }
        $length = $stream.Length
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $digest = $sha256.ComputeHash($stream)
        } finally {
            $sha256.Dispose()
        }
        return [pscustomobject][ordered]@{
            Size = [long]$length
            SHA256 = ConvertTo-LowerHex -Bytes $digest
        }
    } finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
Copies one firmware payload and verifies the exact written bytes.

.DESCRIPTION
Locks the source against writes, hashes it, rewinds the same handle, writes a
new destination without replacement, flushes it, then reopens and rehashes the
destination. A mismatch removes the destination and fails collection.
#>
function Copy-VerifiedFirmwareFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $destinationParent = [System.IO.Path]::GetDirectoryName($DestinationPath)
    [void][System.IO.Directory]::CreateDirectory($destinationParent)
    if ([System.IO.File]::Exists($DestinationPath)) {
        throw 'A platform firmware staging destination already exists.'
    }

    $source = New-Object System.IO.FileStream(
        $SourcePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        if ($source.Length -le 0 -or $source.Length -gt $script:MaximumFirmwareFileBytes) {
            throw 'A selected platform firmware file has an invalid or excessive byte length.'
        }
        $sourceLength = [long]$source.Length
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $sourceDigest = ConvertTo-LowerHex -Bytes $sha256.ComputeHash($source)
        } finally {
            $sha256.Dispose()
        }
        $source.Position = 0

        $destination = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $source.CopyTo($destination, 1MB)
            $destination.Flush($true)
        } finally {
            $destination.Dispose()
        }
    } finally {
        $source.Dispose()
    }

    try {
        $written = Get-FileSHA256 -Path $DestinationPath -MaximumBytes $script:MaximumFirmwareFileBytes
        if ($written.Size -ne $sourceLength -or $written.SHA256 -cne $sourceDigest) {
            throw 'A copied platform firmware file failed its byte-for-byte verification.'
        }
        return $written
    } catch {
        [System.IO.File]::Delete($DestinationPath)
        throw
    }
}

<#
.SYNOPSIS
Resolves the complete firmware policy to unambiguous active packages.

.DESCRIPTION
Searches only DriverStore packages bound to present signed devices. Every
compiled source filename must resolve exactly once, with a valid associated
catalogue, before any proprietary payload is copied to staging.
#>
function Resolve-PlatformFirmware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Policies,

        [Parameter(Mandatory = $true)]
        [object[]]$ActivePackages
    )

    $catalogueCache = @{}
    $resolved = @()
    foreach ($policy in $Policies) {
        $candidates = @()
        foreach ($package in $ActivePackages) {
            $matchedFiles = @(Get-ChildItem -LiteralPath $package.PackageRoot -Filter $policy.SourceName -File -Recurse -Force -ErrorAction Stop)
            foreach ($match in $matchedFiles) {
                Assert-NoReparsePath -Root $package.PackageRoot -Child $match.FullName
                $portablePath = Get-PortableDriverStorePath -SourcePath $match.FullName -CanonicalSourceName $policy.SourceName
                if (-not $catalogueCache.ContainsKey($package.PublishedINF)) {
                    $catalogueCache[$package.PublishedINF] = Get-PackageCatalogueEvidence -Package $package
                }
                $candidates += [pscustomobject][ordered]@{
                    Policy = $policy
                    SourcePath = $match.FullName
                    DriverStorePath = $portablePath
                    PublishedINF = $package.PublishedINF
                    DriverVersion = $package.DriverVersion
                    CatalogueSHA256 = $catalogueCache[$package.PublishedINF].SHA256
                    CatalogueSignature = $catalogueCache[$package.PublishedINF].Signature
                }
            }
        }

        if ($candidates.Count -eq 0) {
            return [pscustomobject][ordered]@{ Available = $false; Records = @() }
        }
        if ($candidates.Count -ne 1) {
            throw "The active signed DriverStore evidence for $($policy.ID) is ambiguous."
        }
        $resolved += $candidates[0]
    }

    return [pscustomobject][ordered]@{ Available = $true; Records = @($resolved) }
}

<#
.SYNOPSIS
Copies and describes the complete resolved platform firmware set.

.DESCRIPTION
Copies all eleven files in canonical order, enforces per-file and total size
bounds, and creates the exact manifest records required by the Go validator.
#>
function New-PlatformFirmwareSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resolution,

        [Parameter(Mandatory = $true)]
        [string]$StagingRoot
    )

    if (-not $Resolution.Available) {
        return [ordered]@{ included = $false; reason = 'unavailable' }
    }

    $records = @()
    [long]$totalBytes = 0
    foreach ($candidate in $Resolution.Records) {
        $destinationPath = Join-Path $StagingRoot $candidate.Policy.PayloadPath.Replace('/', '\')
        $copied = Copy-VerifiedFirmwareFile -SourcePath $candidate.SourcePath -DestinationPath $destinationPath
        $totalBytes += $copied.Size
        if ($totalBytes -gt $script:MaximumFirmwareTotalBytes) {
            throw 'The complete platform firmware payload exceeds the contract total-size limit.'
        }
        $records += [ordered]@{
            id = $candidate.Policy.ID
            source_name = $candidate.Policy.SourceName
            payload_path = $candidate.Policy.PayloadPath
            destination = $candidate.Policy.Destination
            size_bytes = [long]$copied.Size
            sha256 = $copied.SHA256
            windows_source = [ordered]@{
                driver_store_path = $candidate.DriverStorePath
                published_inf = $candidate.PublishedINF
                driver_version = $candidate.DriverVersion
                catalogue_sha256 = $candidate.CatalogueSHA256
                catalogue_signature = $candidate.CatalogueSignature
            }
        }
    }

    return [ordered]@{ included = $true; files = @($records) }
}

<#
.SYNOPSIS
Finds one trusted Bluetooth PermanentAddress with its private adapter identity.

.DESCRIPTION
Uses only Bluetooth-labelled network adapters, excludes Wi-Fi and WLAN names,
requires PermanentAddress rather than a current or Wi-Fi-derived address, and
fails on ambiguity. The raw adapter instance identifier remains in memory.
#>
function Get-NetAdapterBluetoothEvidence {
    [CmdletBinding()]
    param()

    $evidenceByKey = @{}
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)) {
        $name = ([string]$adapter.Name).Trim()
        $description = ([string]$adapter.InterfaceDescription).Trim()
        $label = "$name $description"
        if ($label -notmatch 'Bluetooth' -or $label -match 'Wi-Fi|WiFi|WLAN|802\.11') {
            continue
        }

        $permanentProperty = $adapter.PSObject.Properties['PermanentAddress']
        $instanceProperty = $adapter.PSObject.Properties['PnPDeviceID']
        if ($null -eq $permanentProperty -or $null -eq $instanceProperty -or
            [string]::IsNullOrWhiteSpace([string]$permanentProperty.Value) -or
            [string]::IsNullOrWhiteSpace([string]$instanceProperty.Value)) {
            continue
        }
        try {
            $address = ConvertTo-CanonicalBluetoothAddress -Value ([string]$permanentProperty.Value)
            $instanceID = ConvertTo-CanonicalAdapterInstanceID -Value ([string]$instanceProperty.Value)
        } catch {
            continue
        }
        $key = $address + '|' + $instanceID
        $evidenceByKey[$key] = [pscustomobject][ordered]@{
            Address = $address
            Source = 'net-adapter-permanent-address'
            AdapterInstanceID = $instanceID
        }
    }

    $candidates = @($evidenceByKey.Values)
    if ($candidates.Count -eq 0) {
        return $null
    }
    if ($candidates.Count -ne 1) {
        throw 'Windows exposed more than one eligible Bluetooth PermanentAddress; collection cannot select safely.'
    }
    return $candidates[0]
}

<#
.SYNOPSIS
Finds explicitly confirmed BTHPORT controller evidence.

.DESCRIPTION
Requires exactly one valid local BTHPORT controller-address key and one present
physical Bluetooth radio instance. Invocation with -UseBTHPORTRegistry is the
operator's explicit confirmation; neither raw adapter identity nor SMBIOS UUID
is written or displayed.
#>
function Get-BTHPORTBluetoothEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PresentPnpDevices
    )

    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys'
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return $null
    }

    $addressMap = @{}
    foreach ($key in @(Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop)) {
        try {
            $address = ConvertTo-CanonicalBluetoothAddress -Value ([string]$key.PSChildName)
            $addressMap[$address] = $address
        } catch {
            continue
        }
    }
    $addresses = @($addressMap.Values)
    if ($addresses.Count -eq 0) {
        return $null
    }
    if ($addresses.Count -ne 1) {
        throw 'BTHPORT contains more than one eligible local controller address; collection cannot select safely.'
    }

    $radioIDs = @{}
    foreach ($device in $PresentPnpDevices) {
        $className = ([string]$device.Class).Trim()
        $friendlyName = ([string]$device.FriendlyName).Trim()
        $rawInstanceID = ([string]$device.InstanceId).Trim()
        if ($className -ine 'Bluetooth' -or $friendlyName -notmatch 'Radio|Qualcomm|FastConnect|WCN|Bluetooth' -or
            $rawInstanceID -match '^(?:BTH|BTHENUM|SWD|ROOT)\\') {
            continue
        }
        try {
            $instanceID = ConvertTo-CanonicalAdapterInstanceID -Value $rawInstanceID
            $radioIDs[$instanceID] = $instanceID
        } catch {
            continue
        }
    }
    $instances = @($radioIDs.Values)
    if ($instances.Count -eq 0) {
        return $null
    }
    if ($instances.Count -ne 1) {
        throw 'Windows exposes more than one eligible physical Bluetooth radio; collection cannot select safely.'
    }

    return [pscustomobject][ordered]@{
        Address = $addresses[0]
        Source = 'bthport-registry-operator-confirmed'
        AdapterInstanceID = $instances[0]
    }
}

<#
.SYNOPSIS
Writes text as BOM-less UTF-8 without replacing an existing file.

.DESCRIPTION
Uses a CreateNew FileStream and a UTF8Encoding configured without a byte-order
mark because the strict Go decoder rejects BOM-prefixed JSON.
#>
function Write-NewUTF8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $bytes = $encoding.GetBytes($Content)
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
Verifies the staged hand-off as an exact closed directory.

.DESCRIPTION
Rejects extra, missing, reparse or special entries; rehashes every declared
payload; confirms the JSON is BOM-less and bounded; and proves raw SMBIOS and
Bluetooth adapter identifiers were not persisted.
#>
function Assert-ClosedHandoffDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$RawSMBIOSUUID,

        [AllowNull()]
        [string]$RawBluetoothAdapterInstanceID
    )

    $expectedFiles = @{}
    $expectedDirectories = @{ '.' = $true }
    $expectedFiles[$script:ManifestFilename] = $true
    if ($Manifest.platform_firmware.included) {
        foreach ($record in $Manifest.platform_firmware.files) {
            $expectedFiles[$record.payload_path] = $true
            $relativeParent = [System.IO.Path]::GetDirectoryName($record.payload_path.Replace('/', '\'))
            while (-not [string]::IsNullOrEmpty($relativeParent)) {
                $expectedDirectories[$relativeParent.Replace('\', '/')] = $true
                $relativeParent = [System.IO.Path]::GetDirectoryName($relativeParent)
            }
        }
    }

    $seenFiles = @{}
    $seenDirectories = @{ '.' = $true }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The staged Windows hand-off contains a reparse point.'
        }
        $relative = $item.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
        if ($item.PSIsContainer) {
            $seenDirectories[$relative] = $true
        } else {
            $seenFiles[$relative] = $true
        }
    }
    if (@($expectedFiles.Keys | Where-Object { -not $seenFiles.ContainsKey($_) }).Count -ne 0 -or
        @($seenFiles.Keys | Where-Object { -not $expectedFiles.ContainsKey($_) }).Count -ne 0 -or
        @($expectedDirectories.Keys | Where-Object { -not $seenDirectories.ContainsKey($_) }).Count -ne 0 -or
        @($seenDirectories.Keys | Where-Object { -not $expectedDirectories.ContainsKey($_) }).Count -ne 0) {
        throw 'The staged Windows hand-off is not the exact closed manifest and payload set.'
    }

    $manifestPath = Join-Path $Root $script:ManifestFilename
    $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    if ($manifestBytes.Length -eq 0 -or $manifestBytes.Length -gt $script:MaximumManifestBytes -or
        ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF)) {
        throw 'The staged Windows hand-off manifest is empty, oversized or BOM-prefixed.'
    }
    $strictUTF8 = New-Object System.Text.UTF8Encoding($false, $true)
    $manifestText = $strictUTF8.GetString($manifestBytes)
    if ($manifestText.IndexOf($RawSMBIOSUUID, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        (-not [string]::IsNullOrEmpty($RawBluetoothAdapterInstanceID) -and
         $manifestText.IndexOf($RawBluetoothAdapterInstanceID, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
        throw 'The staged Windows hand-off persisted a forbidden raw hardware identifier.'
    }
    [void]($manifestText | ConvertFrom-Json -ErrorAction Stop)

    if ($Manifest.platform_firmware.included) {
        foreach ($record in $Manifest.platform_firmware.files) {
            $payloadPath = Join-Path $Root $record.payload_path.Replace('/', '\')
            $actual = Get-FileSHA256 -Path $payloadPath -MaximumBytes $script:MaximumFirmwareFileBytes
            if ($actual.Size -ne [long]$record.size_bytes -or $actual.SHA256 -cne $record.sha256) {
                throw "The staged payload for $($record.id) no longer matches its manifest."
            }
        }
    }
}

<#
.SYNOPSIS
Publishes one verified staging directory without replacement.

.DESCRIPTION
Rechecks that the requested destination remains absent, then performs a
same-parent Directory.Move. No existing directory is overwritten or merged.
#>
function Publish-HandoffDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$FinalPath
    )

    if (Test-Path -LiteralPath $FinalPath) {
        throw 'The Windows hand-off destination appeared during collection; nothing was replaced.'
    }
    [System.IO.Directory]::Move($StagingPath, $FinalPath)
}

Assert-BindingSelfTest
if ($SelfTest) {
    Assert-PortableFileSelfTest
    Write-Host 'Windows hand-off binding self-test passed.'
    return
}

Assert-CollectorHost
if ($UseBTHPORTRegistry -and $Components -eq 'PlatformFirmware') {
    throw '-UseBTHPORTRegistry requires Bluetooth collection.'
}

$transaction = New-OutputTransaction -RequestedPath $OutputDirectory
$stagingActive = $true
$salt = $null
$rawSMBIOSUUID = $null
$rawAdapterInstanceID = $null
try {
    Write-Host 'Collecting a private, device-bound Windows hand-off.'
    Write-Host 'Do not publish the output or include it in a redistributable image.'

    $deviceEvidence = Get-SupportedDeviceEvidence
    $rawSMBIOSUUID = $deviceEvidence.SMBIOSUUID
    $salt = New-BindingSalt
    $bindingSalt = ConvertTo-LowerHex -Bytes $salt
    $deviceBinding = Get-DomainSeparatedBinding -Domain $script:DeviceBindingDomain -Salt $salt -CanonicalValue $rawSMBIOSUUID

    $firmwareRequested = $Components -eq 'Both' -or $Components -eq 'PlatformFirmware'
    $bluetoothRequested = $Components -eq 'Both' -or $Components -eq 'Bluetooth'

    if ($firmwareRequested) {
        $policies = @(Get-PlatformFirmwarePolicy)
        $activePackages = @(Get-ActiveDriverPackages -PresentPnpDevices $deviceEvidence.PresentPnpDevices)
        $resolution = Resolve-PlatformFirmware -Policies $policies -ActivePackages $activePackages
        $firmwareSection = New-PlatformFirmwareSection -Resolution $resolution -StagingRoot $transaction.StagingPath
        if (-not $firmwareSection.included) {
            Write-Warning 'The complete eleven-file active signed platform firmware set is unavailable.'
        }
    } else {
        $firmwareSection = [ordered]@{ included = $false; reason = 'not-requested' }
    }

    if ($bluetoothRequested) {
        if ($UseBTHPORTRegistry) {
            $bluetoothEvidence = Get-BTHPORTBluetoothEvidence -PresentPnpDevices $deviceEvidence.PresentPnpDevices
        } else {
            $bluetoothEvidence = Get-NetAdapterBluetoothEvidence
        }
        if ($null -eq $bluetoothEvidence) {
            $bluetoothSection = [ordered]@{ included = $false; reason = 'unavailable' }
            Write-Warning 'A trusted same-device Bluetooth public address is unavailable.'
        } else {
            $rawAdapterInstanceID = $bluetoothEvidence.AdapterInstanceID
            $adapterBinding = Get-DomainSeparatedBinding -Domain $script:BluetoothAdapterBindingDomain -Salt $salt -CanonicalValue $rawAdapterInstanceID
            $bluetoothSection = [ordered]@{
                included = $true
                address = $bluetoothEvidence.Address
                source = $bluetoothEvidence.Source
                adapter_instance_id_binding_sha256 = $adapterBinding
            }
            $bluetoothEvidence.AdapterInstanceID = $null
            $bluetoothEvidence = $null
        }
    } else {
        $bluetoothSection = [ordered]@{ included = $false; reason = 'not-requested' }
    }

    if (-not $firmwareSection.included -and -not $bluetoothSection.included) {
        throw 'A valid Windows hand-off must include platform firmware, a Bluetooth public address, or both.'
    }

    $manifest = [ordered]@{
        schema_version = 1
        kind = 'linux-armer.windows-handoff'
        privacy_classification = 'private-device-bound'
        created_at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        collector = [ordered]@{
            name = $script:CollectorName
            version = $script:CollectorVersion
        }
        device = [ordered]@{
            platform_id = 'microsoft-surface-pro-11'
            architecture = 'arm64'
            binding_salt = $bindingSalt
            smbios_product_uuid_binding_sha256 = $deviceBinding
            wifi_pci_id = '17cb:1107'
        }
        platform_firmware = $firmwareSection
        bluetooth_public_address = $bluetoothSection
    }

    $json = ($manifest | ConvertTo-Json -Depth 12) + "`n"
    $manifestPath = Join-Path $transaction.StagingPath $script:ManifestFilename
    Write-NewUTF8File -Path $manifestPath -Content $json
    Assert-ClosedHandoffDirectory -Root $transaction.StagingPath -Manifest $manifest -RawSMBIOSUUID $rawSMBIOSUUID -RawBluetoothAdapterInstanceID $rawAdapterInstanceID

    Publish-HandoffDirectory -StagingPath $transaction.StagingPath -FinalPath $transaction.FinalPath
    $stagingActive = $false

    Write-Host 'Windows hand-off collection complete.'
    Write-Host "Private output directory: $($transaction.FinalPath)"
    Write-Host 'Import it with linux-armer, then purge every unneeded copy.'
} catch {
    $collectionError = $_
    if ($stagingActive -and $null -ne $transaction -and (Test-Path -LiteralPath $transaction.StagingPath)) {
        try {
            Remove-Item -LiteralPath $transaction.StagingPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Collection failed and the private staging directory could not be removed: $($transaction.StagingPath)"
        }
    }
    throw $collectionError
} finally {
    if ($null -ne $salt) {
        [Array]::Clear($salt, 0, $salt.Length)
    }
    $rawSMBIOSUUID = $null
    $rawAdapterInstanceID = $null
}
