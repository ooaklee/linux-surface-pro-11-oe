<#
.SYNOPSIS
Collects a private Surface Pro 11 Windows hand-off for linux-armer.

.DESCRIPTION
Creates the strict version 2 Windows hand-off directory consumed by
`linux-armer handoff import`. The collector can include the complete audited
eleven-file platform firmware set, the same-device Bluetooth public address,
or both. It never exports Windows Wi-Fi firmware.

The complete hand-off is private, device-bound material. It contains
proprietary firmware, salted hardware bindings, Windows driver provenance and,
when available, a Bluetooth public address. Keep it on trusted storage, do not
publish it, and purge it when it is no longer required.

.PARAMETER OutputDirectory
Specifies a new directory to create beneath a pre-provisioned private parent.
The parent must be on local NTFS, have a protected DACL owned by Local System
or Administrators, and grant inheritable full control only to those two
principals. Every ancestor must be non-reparse and protected against
medium-integrity redirection. The destination must not exist. Collect locally,
then copy the completed private directory to trusted removable storage.

.PARAMETER Components
Chooses Both, PlatformFirmware or Bluetooth. A deliberately excluded section
is recorded as not-requested. A requested but unavailable section is recorded
as unavailable only when the other section can still make a valid hand-off.

.PARAMETER UseBTHPORTRegistry
Explicitly requires the sole local BTHPORT controller-address key to agree with
the built-in radio's independently correlated network-adapter PermanentAddress.
An uncorrelated registry value is never accepted. The raw adapter instance
identifier is never written to disk or displayed.

.PARAMETER SelfTest
Runs the pinned device-binding, manifest, file-copy and encoding checks without
collecting device data. This parameter set does not require Windows or
administrator privileges.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -OutputDirectory C:\ProgramData\linux-armer-private\sp11-handoff

Collects both supported sections into a new directory.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -OutputDirectory C:\ProgramData\linux-armer-private\sp11-handoff -Components PlatformFirmware

Collects only the complete platform firmware set and records Bluetooth as not
requested.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\collect-sp11-windows-handoff.ps1 -SelfTest

Checks that this script's contract implementation matches the Go contract's
pinned values and strict version 2 manifest shape.
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
$script:CollectorVersion = '2.0.0'
$script:ManifestFilename = 'linux-armer-windows-handoff.json'
$script:DeviceBindingDomain = 'linux-armer.windows-handoff/device-binding/v1'
$script:MaximumManifestBytes = 1MB
$script:MaximumFirmwareFileBytes = 512MB
$script:MaximumFirmwareTotalBytes = 1GB
$script:AdministratorsSID = 'S-1-5-32-544'
$script:SystemSID = 'S-1-5-18'
$script:TrustedInstallerSID = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$script:BuiltInBluetoothHardwareID = 'QCA_SHB\UART_H4_HMT'
$script:BuiltInBluetoothTransportHardwareID = 'ACPI\QCOM0D04'

<#
.SYNOPSIS
Loads the Windows file-identity reader used at privileged path boundaries.

.DESCRIPTION
Compiles one small Windows API wrapper on first use. The wrapper opens the
named object itself with reparse-point traversal disabled and returns its
volume serial number, file identifier and attributes. This gives the
PowerShell 5.1 collector a stable object identity rather than trusting a path
string across privileged operations.
#>
function Initialize-WindowsFileIdentityReader {
    [CmdletBinding()]
    param()

    if ($env:OS -cne 'Windows_NT') {
        throw 'Windows file-object identity is available only on Windows.'
    }
    if ($null -ne ('LinuxArmer.WindowsFileIdentityReader' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace LinuxArmer
{
    /// <summary>Describes one opened Windows filesystem object without exposing a mutable path as identity.</summary>
    public sealed class WindowsFileIdentity
    {
        /// <summary>Gets the volume-and-file identifier used for equality checks.</summary>
        public string Token { get; private set; }

        /// <summary>Gets the attributes observed on the no-follow object handle.</summary>
        public FileAttributes Attributes { get; private set; }

        /// <summary>Creates one immutable file-identity result.</summary>
        public WindowsFileIdentity(string token, FileAttributes attributes)
        {
            Token = token;
            Attributes = attributes;
        }
    }

    /// <summary>Reads Windows file identities through no-follow object handles.</summary>
    public static class WindowsFileIdentityReader
    {
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;

        /// <summary>Contains the stable metadata returned for an opened filesystem object.</summary>
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        /// <summary>Opens a path while retaining the final reparse point rather than following it.</summary>
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        /// <summary>Reads stable object metadata from an already opened handle.</summary>
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        /// <summary>Opens one existing object without following its final reparse point and returns its identity.</summary>
        public static WindowsFileIdentity Read(string path)
        {
            using (SafeFileHandle handle = CreateFile(
                path,
                0,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open a Windows filesystem object for an identity check.");
                }
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read a Windows filesystem object identity.");
                }
                string token = String.Format(
                    System.Globalization.CultureInfo.InvariantCulture,
                    "{0:x8}:{1:x8}{2:x8}",
                    information.VolumeSerialNumber,
                    information.FileIndexHigh,
                    information.FileIndexLow);
                return new WindowsFileIdentity(token, (FileAttributes)information.FileAttributes);
            }
        }
    }
}
'@
}

<#
.SYNOPSIS
Returns one no-follow Windows filesystem-object identity.

.DESCRIPTION
Opens the final path component without traversing a reparse point and rejects
any reparse object. The returned token combines the volume serial number and
the filesystem file identifier and is safe to compare but not persisted.
#>
function Get-WindowsFileObjectIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Initialize-WindowsFileIdentityReader
    $identity = [LinuxArmer.WindowsFileIdentityReader]::Read([System.IO.Path]::GetFullPath($Path))
    if (($identity.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'A privileged Windows hand-off path became a reparse point.'
    }
    return $identity.Token
}

<#
.SYNOPSIS
Reports whether one security identifier is trusted for privileged storage.

.DESCRIPTION
Recognises only Local System, the built-in Administrators group and, for
already existing ancestor directories, the Windows Modules Installer service.
The hand-off output parent itself uses only System and Administrators.
#>
function Test-TrustedStorageSID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SID,

        [switch]$AllowTrustedInstaller
    )

    return $SID -ceq $script:SystemSID -or
        $SID -ceq $script:AdministratorsSID -or
        ($AllowTrustedInstaller -and $SID -ceq $script:TrustedInstallerSID)
}

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
Runs the contract's pinned device-binding derivation vector.

.DESCRIPTION
Proves that the PowerShell byte order, NUL separator, salt decoding and UUID
normalisation produce the exact value pinned by the Go implementation.
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

        $manifest = New-HandoffManifest `
            -CreatedAt '2026-08-30T12:00:00Z' `
            -BindingSalt ('01' * 32) `
            -DeviceBinding ('02' * 32) `
            -PlatformFirmware ([ordered]@{ included = $false; reason = 'not-requested' }) `
            -BluetoothPublicAddress ([ordered]@{ included = $true; address = '10:20:30:40:50:60'; source = 'net-adapter-permanent-address' })
        if (($manifest.Keys -join '|') -cne 'schema_version|kind|privacy_classification|created_at|collector|device|platform_firmware|bluetooth_public_address' -or
            $manifest.schema_version -ne 2 -or $manifest.collector.version -cne '2.0.0' -or
            ($manifest.bluetooth_public_address.Keys -join '|') -cne 'included|address|source') {
            throw 'The strict version 2 manifest-shape self-test did not match its pinned fields.'
        }
        $manifestJSON = $manifest | ConvertTo-Json -Depth 12
        if ($manifestJSON.IndexOf('adapter_instance_id_binding_sha256', [System.StringComparison]::Ordinal) -ge 0) {
            throw 'The strict version 2 manifest-shape self-test found a retired field.'
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
It also requires the elevated token's default owner to be Administrators or
System, so every newly created descendant has a trusted owner from its first
filesystem-visible moment.
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

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $ownerSID = $identity.Owner.Value
    } finally {
        $identity.Dispose()
    }
    if (-not (Test-TrustedStorageSID -SID $ownerSID)) {
        throw 'The elevated Windows token must use Local System or Administrators as its default filesystem owner.'
    }

    foreach ($commandName in @(
        'Get-CimInstance',
        'Get-PnpDevice',
        'Get-PnpDeviceProperty',
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
Keeps the PowerShell collector's identifiers, source filenames, authoritative
original INF basenames, payload paths and Linux destinations byte-for-byte
aligned with the Go contract. Windows Wi-Fi firmware is intentionally absent
from this closed allow-list.
#>
function Get-PlatformFirmwarePolicy {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject][ordered]@{ ID = 'gpu-main'; SourceName = 'qcdxkmsuc8380.mbn'; SourceINF = 'qcdx8380.inf'; PayloadPath = 'payload/platform-firmware/qcdxkmsuc8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'gpu-purwa'; SourceName = 'qcdxkmsucpurwa.mbn'; SourceINF = 'qcdx8380.inf'; PayloadPath = 'payload/platform-firmware/qcdxkmsucpurwa.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-dtb'; SourceName = 'adsp_dtbs.elf'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/adsp_dtbs.elf'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-main'; SourceName = 'qcadsp8380.mbn'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/qcadsp8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'adsp-resource'; SourceName = 'adspr.jsn'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/adspr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn' },
        [pscustomobject][ordered]@{ ID = 'adsp-system'; SourceName = 'adsps.jsn'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/adsps.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn' },
        [pscustomobject][ordered]@{ ID = 'adsp-user'; SourceName = 'adspua.jsn'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/adspua.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn' },
        [pscustomobject][ordered]@{ ID = 'battery-manager'; SourceName = 'battmgr.jsn'; SourceINF = 'surfacepro_ext_adsp8380.inf'; PayloadPath = 'payload/platform-firmware/battmgr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-dtb'; SourceName = 'cdsp_dtbs.elf'; SourceINF = 'qcnspmcdm_ext_cdsp8380.inf'; PayloadPath = 'payload/platform-firmware/cdsp_dtbs.elf'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-main'; SourceName = 'qccdsp8380.mbn'; SourceINF = 'qcnspmcdm_ext_cdsp8380.inf'; PayloadPath = 'payload/platform-firmware/qccdsp8380.mbn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn' },
        [pscustomobject][ordered]@{ ID = 'cdsp-resource'; SourceName = 'cdspr.jsn'; SourceINF = 'qcnspmcdm_ext_cdsp8380.inf'; PayloadPath = 'payload/platform-firmware/cdspr.jsn'; Destination = 'lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn' }
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
Returns one exact Windows PnP property value.

.DESCRIPTION
Queries one named property for an in-memory canonical instance identifier and
requires exactly one successful record. Errors never include either the raw
identifier or property data.
#>
function Get-ExactPnpPropertyData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceID,

        [Parameter(Mandatory = $true)]
        [string]$KeyName
    )

    try {
        $records = @(Get-PnpDeviceProperty -InstanceId $InstanceID -KeyName $KeyName -ErrorAction Stop |
            Where-Object { ([string]$_.KeyName).Trim() -ieq $KeyName })
    } catch {
        throw 'Windows could not read one required Bluetooth PnP property.'
    }
    if ($records.Count -ne 1 -or $null -eq $records[0].Data) {
        throw 'Windows did not provide one exact required Bluetooth PnP property.'
    }
    return $records[0].Data
}

<#
.SYNOPSIS
Reports whether one PnP object descends from an exact physical ancestor.

.DESCRIPTION
Walks the structured DEVPKEY_Device_Parent chain with canonical, cycle-checked
identifiers and a compiled depth bound. It never relies on friendly names and
never writes or displays an identifier.
#>
function Test-PnpDeviceDescendsFrom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidateInstanceID,

        [Parameter(Mandatory = $true)]
        [string]$AncestorInstanceID
    )

    try {
        $current = ConvertTo-CanonicalAdapterInstanceID -Value $CandidateInstanceID
        $ancestor = ConvertTo-CanonicalAdapterInstanceID -Value $AncestorInstanceID
    } catch {
        return $false
    }
    $visited = @{}
    for ($depth = 0; $depth -lt 32; $depth++) {
        if ($current -ceq $ancestor) {
            return $true
        }
        if ($visited.ContainsKey($current)) {
            return $false
        }
        $visited[$current] = $true
        try {
            $parentData = Get-ExactPnpPropertyData -InstanceID $current -KeyName 'DEVPKEY_Device_Parent'
            $current = ConvertTo-CanonicalAdapterInstanceID -Value ([string]$parentData)
        } catch {
            return $false
        }
    }
    return $false
}

<#
.SYNOPSIS
Finds the exact built-in Surface Pro 11 Bluetooth radio and transport.

.DESCRIPTION
Requires one present physical Bluetooth radio, the WCN7850-specific
QCA_SHB\UART_H4_HMT hardware identifier, and its ACPI\QCOM0D04 parent
transport with matching hardware identity. Any external or ambiguous physical
radio causes collection to fail closed. Raw PnP identifiers remain in memory.
#>
function Get-BuiltInBluetoothRadioEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PresentPnpDevices
    )

    $physicalRadios = @{}
    foreach ($device in $PresentPnpDevices) {
        if (([string]$device.Class).Trim() -ine 'Bluetooth') {
            continue
        }
        try {
            $instanceID = ConvertTo-CanonicalAdapterInstanceID -Value ([string]$device.InstanceId)
        } catch {
            throw 'Windows exposes a Bluetooth-class object with an unusable physical identity; collection cannot select safely.'
        }
        if ($instanceID -match '^(?:BTH|BTHENUM|SWD|ROOT|HTREE)\\' -or
            $instanceID -match '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}\\' -or
            $instanceID -match ('^' + [regex]::Escape($script:BuiltInBluetoothTransportHardwareID) + '(?:\\|$)')) {
            continue
        }
        # Treat every remaining Bluetooth-class object as physical. Unknown bus
        # enumerators must increase ambiguity rather than becoming an allow-list
        # gap through which an attached controller could be silently ignored.
        $physicalRadios[$instanceID] = $instanceID
    }
    $radios = @($physicalRadios.Values)
    if ($radios.Count -eq 0) {
        return $null
    }
    if ($radios.Count -ne 1 -or
        $radios[0] -notmatch ('^' + [regex]::Escape($script:BuiltInBluetoothHardwareID) + '(?:\\|$)')) {
        throw 'Windows exposes an external or ambiguous physical Bluetooth radio; collection cannot select safely.'
    }

    $radioID = $radios[0]
    $radioHardwareIDs = @(Get-ExactPnpPropertyData -InstanceID $radioID -KeyName 'DEVPKEY_Device_HardwareIds' |
        ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    if (@($radioHardwareIDs | Where-Object { $_ -ceq $script:BuiltInBluetoothHardwareID }).Count -ne 1) {
        throw 'The present Bluetooth radio does not have the compiled Surface Pro 11 hardware identity.'
    }
    $transportID = ConvertTo-CanonicalAdapterInstanceID -Value ([string](Get-ExactPnpPropertyData -InstanceID $radioID -KeyName 'DEVPKEY_Device_Parent'))
    if ($transportID -notmatch ('^' + [regex]::Escape($script:BuiltInBluetoothTransportHardwareID) + '(?:\\|$)')) {
        throw 'The present Bluetooth radio is not attached to the compiled Surface Pro 11 ACPI transport.'
    }
    $transportHardwareIDs = @(Get-ExactPnpPropertyData -InstanceID $transportID -KeyName 'DEVPKEY_Device_HardwareIds' |
        ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    if (@($transportHardwareIDs | Where-Object { $_ -ceq $script:BuiltInBluetoothTransportHardwareID }).Count -ne 1) {
        throw 'The present Bluetooth transport does not have the compiled Surface Pro 11 hardware identity.'
    }

    return [pscustomobject][ordered]@{
        RadioInstanceID = $radioID
        TransportInstanceID = $transportID
    }
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
Checks that a directory has the collector's exact private ACL.

.DESCRIPTION
Requires a protected DACL, an Administrators or System owner, and inheritable
full-control entries for only Administrators and System. A medium-integrity
process therefore cannot create, replace, relink, delete or take ownership of
transaction objects beneath this directory.
#>
function Assert-PrivateDirectoryACL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    $security = [System.IO.Directory]::GetAccessControl($Path, $sections)
    $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if (-not (Test-TrustedStorageSID -SID $owner)) {
        throw 'The private output directory owner must be Local System or the built-in Administrators group.'
    }
    if (-not $security.AreAccessRulesProtected) {
        throw 'The private output directory must have inheritance disabled on its DACL.'
    }

    $fullControl = [long][System.Security.AccessControl.FileSystemRights]::FullControl
    $requiredInheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $fullControlBySID = @{}
    $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or -not (Test-TrustedStorageSID -SID $sid) -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            ([long]$rule.FileSystemRights -band $fullControl) -ne $fullControl -or
            ($rule.InheritanceFlags -band $requiredInheritance) -ne $requiredInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            throw 'The private output directory DACL must contain only explicit inheritable full-control entries for Local System and Administrators.'
        }
        $fullControlBySID[$sid] = $true
    }
    if (-not $fullControlBySID.ContainsKey($script:SystemSID) -or
        -not $fullControlBySID.ContainsKey($script:AdministratorsSID)) {
        throw 'The private output directory DACL must grant inheritable full control to Local System and Administrators.'
    }
}

<#
.SYNOPSIS
Applies the collector's exact private ACL to a new transaction directory.

.DESCRIPTION
Sets the owner to the built-in Administrators group, disables inheritance and
grants inheritable full control only to Local System and Administrators. The
directory is created beneath an already verified parent, so there is no
medium-integrity access window before this ACL is applied.
#>
function Set-PrivateDirectoryACL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $administrators = New-Object System.Security.Principal.SecurityIdentifier($script:AdministratorsSID)
    $system = New-Object System.Security.Principal.SecurityIdentifier($script:SystemSID)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administrators, $fullControl, $inheritance, $propagation, $allow)))
    [void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $fullControl, $inheritance, $propagation, $allow)))
    [System.IO.Directory]::SetAccessControl($Path, $security)
    Assert-PrivateDirectoryACL -Path $Path
}

<#
.SYNOPSIS
Checks that ancestors cannot redirect one privileged output path.

.DESCRIPTION
Walks from the filesystem root down to the output parent, rejecting reparse
points, untrusted ownership and untrusted delete or security-control rights.
It reads each object's no-follow identity before and after its ACL so a path
replacement during verification fails closed. The immediate output parent
must satisfy the exact private ACL rather than the narrower ancestor policy.
#>
function Assert-SecureOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $paths = @()
    $current = New-Object System.IO.DirectoryInfo([System.IO.Path]::GetFullPath($ParentPath))
    while ($null -ne $current) {
        $paths = @($current.FullName) + $paths
        $current = $current.Parent
    }

    $dangerousAncestorRights = [long](
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes)
    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    $parentIdentity = $null
    foreach ($path in $paths) {
        $beforeIdentity = Get-WindowsFileObjectIdentity -Path $path
        $security = [System.IO.Directory]::GetAccessControl($path, $sections)
        $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if (-not (Test-TrustedStorageSID -SID $owner -AllowTrustedInstaller)) {
            throw 'The Windows hand-off output path has an ancestor owned by a medium-integrity principal.'
        }
        foreach ($rule in @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $inheritOnly = ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
            if (-not $inheritOnly -and
                $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                -not (Test-TrustedStorageSID -SID $rule.IdentityReference.Value -AllowTrustedInstaller) -and
                (([long]$rule.FileSystemRights -band $dangerousAncestorRights) -ne 0)) {
                throw 'The Windows hand-off output path has an ancestor that a medium-integrity principal can redirect.'
            }
        }
        $afterIdentity = Get-WindowsFileObjectIdentity -Path $path
        if ($beforeIdentity -cne $afterIdentity) {
            throw 'A Windows hand-off output ancestor changed during its security check.'
        }
        if ($path -ieq [System.IO.Path]::GetFullPath($ParentPath)) {
            Assert-PrivateDirectoryACL -Path $path
            $parentIdentity = $afterIdentity
        }
    }
    if ([string]::IsNullOrEmpty($parentIdentity)) {
        throw 'The Windows hand-off output parent identity could not be retained.'
    }
    return $parentIdentity
}

<#
.SYNOPSIS
Reports whether a named immediate directory entry already exists.

.DESCRIPTION
Enumerates only the verified parent rather than following the candidate path.
Case-insensitive comparison also catches reparse points with unavailable
targets and Windows case aliases that ordinary existence helpers may miss.
#>
function Test-ImmediateDirectoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($entry in @((Get-Item -LiteralPath $ParentPath -Force).GetFileSystemInfos())) {
        if ($entry.Name -ieq $Name) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Allocates a protected same-filesystem transaction for one new output.

.DESCRIPTION
Requires a local NTFS parent with an administrator-only private DACL and a
non-redirectable ancestor chain. It creates an unpredictable sibling staging
directory, applies the same private DACL and retains the parent and staging
filesystem identities for every later sensitive boundary.
#>
function New-OutputTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedPath
    )

    $finalPath = [System.IO.Path]::GetFullPath($RequestedPath)
    $rootPath = [System.IO.Path]::GetPathRoot($finalPath)
    if ($finalPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        throw 'The private Windows hand-off output must be on a local NTFS filesystem, not a network share.'
    }
    $drive = New-Object System.IO.DriveInfo($rootPath)
    if (-not $drive.IsReady -or
        ($drive.DriveType -ne [System.IO.DriveType]::Fixed -and $drive.DriveType -ne [System.IO.DriveType]::Removable) -or
        $drive.DriveFormat -ine 'NTFS') {
        throw 'The private Windows hand-off output requires a ready local NTFS filesystem.'
    }
    if ($finalPath.TrimEnd('\', '/') -ieq $rootPath.TrimEnd('\', '/')) {
        throw 'The Windows hand-off output must not be a filesystem root.'
    }

    $parentInfo = [System.IO.Directory]::GetParent($finalPath)
    if ($null -eq $parentInfo -or -not $parentInfo.Exists) {
        throw 'The Windows hand-off output parent directory must already exist.'
    }
    $finalName = [System.IO.Path]::GetFileName($finalPath.TrimEnd('\', '/'))
    if ([string]::IsNullOrWhiteSpace($finalName) -or $finalName.Length -gt 120 -or
        $finalName.EndsWith('.') -or $finalName -match '[\x00-\x1F<>:"/\\|?*]') {
        throw 'The Windows hand-off output leaf name is not a safe portable directory name.'
    }

    $parentIdentity = Assert-SecureOutputPath -ParentPath $parentInfo.FullName
    if (Test-ImmediateDirectoryEntry -ParentPath $parentInfo.FullName -Name $finalName) {
        throw 'The Windows hand-off output directory already exists; choose a new path.'
    }

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $stagingName = '.linux-armer-collecting-' + [guid]::NewGuid().ToString('N')
        if (Test-ImmediateDirectoryEntry -ParentPath $parentInfo.FullName -Name $stagingName) {
            continue
        }
        $stagingPath = Join-Path $parentInfo.FullName $stagingName
        $stagingCreated = $false
        $stagingIdentity = $null
        try {
            [void][System.IO.Directory]::CreateDirectory($stagingPath)
            $stagingCreated = $true
            Set-PrivateDirectoryACL -Path $stagingPath
            $stagingIdentity = Get-WindowsFileObjectIdentity -Path $stagingPath
            if ((Get-WindowsFileObjectIdentity -Path $parentInfo.FullName) -cne $parentIdentity) {
                throw 'The Windows hand-off output parent changed while allocating staging.'
            }
        } catch {
            $allocationError = $_
            if ($stagingCreated) {
                try {
                    Remove-ClosedDirectoryNoFollow -Root $stagingPath -ExpectedRootIdentity $stagingIdentity
                } catch {
                    Write-Warning "Could not remove a failed private staging allocation: $stagingPath"
                }
            }
            throw $allocationError
        }
        return [pscustomobject][ordered]@{
            ParentPath = $parentInfo.FullName
            ParentIdentity = $parentIdentity
            FinalPath = $finalPath
            FinalName = $finalName
            StagingPath = $stagingPath
            StagingName = $stagingName
            StagingIdentity = $stagingIdentity
        }
    }
    throw 'Could not allocate an unused Windows hand-off staging directory.'
}

<#
.SYNOPSIS
Revalidates the retained identities and ACLs of one output transaction.

.DESCRIPTION
Checks the protected parent and the staging object before and after each
sensitive filesystem boundary. After publication, the same staging identity
must appear at the final path. This rejects object substitution even when a
path string remains unchanged.
#>
function Assert-OutputTransactionBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Transaction,

        [switch]$Published
    )

    if ((Get-WindowsFileObjectIdentity -Path $Transaction.ParentPath) -cne $Transaction.ParentIdentity) {
        throw 'The protected Windows hand-off output parent changed during collection.'
    }
    Assert-PrivateDirectoryACL -Path $Transaction.ParentPath
    $activePath = if ($Published) { $Transaction.FinalPath } else { $Transaction.StagingPath }
    $activeIdentity = Get-WindowsFileObjectIdentity -Path $activePath
    if ($activeIdentity -cne $Transaction.StagingIdentity) {
        throw 'The protected Windows hand-off transaction object changed during collection.'
    }
    Assert-PrivateDirectoryACL -Path $activePath
}

<#
.SYNOPSIS
Returns an exact no-follow inventory beneath a protected directory.

.DESCRIPTION
Enumerates one directory level at a time, rejects every reparse point before
descending and optionally rechecks the retained transaction identity at each
level. It never uses recursive provider traversal across a mutable path.
#>
function Get-ClosedDirectoryEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [AllowNull()]
        [object]$Transaction
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($rootPath)
    $entries = New-Object System.Collections.ArrayList
    while ($pending.Count -gt 0) {
        if ($null -ne $Transaction) {
            Assert-OutputTransactionBoundary -Transaction $Transaction
        }
        $directoryPath = $pending.Pop()
        $directory = Get-Item -LiteralPath $directoryPath -Force
        if (-not $directory.PSIsContainer -or
            ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The staged Windows hand-off contains a reparse or non-directory traversal object.'
        }
        foreach ($item in @($directory.GetFileSystemInfos())) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'The staged Windows hand-off contains a reparse point.'
            }
            [void]$entries.Add($item)
            if (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push($item.FullName)
            }
        }
    }
    return @($entries)
}

<#
.SYNOPSIS
Deletes one reparse object without visiting its target.

.DESCRIPTION
Uses non-recursive directory deletion for Windows junctions and symbolic
directories, with file deletion as the portable symbolic-link fallback used
by cross-platform tests. Both operations address the link itself.
#>
function Remove-ReparseObjectNoFollow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    try {
        [System.IO.Directory]::Delete($Item.FullName, $false)
    } catch [System.IO.IOException] {
        [System.IO.File]::Delete($Item.FullName)
    }
}

<#
.SYNOPSIS
Deletes one closed directory tree without following reparse points.

.DESCRIPTION
Walks one level at a time and removes each file, empty directory or reparse
object directly. Reparse directories are deleted as links and are never
entered. An optional retained root identity is checked throughout privileged
cleanup, so an exchanged transaction path is preserved for manual recovery
rather than recursively traversed.
#>
function Remove-ClosedDirectoryNoFollow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [AllowNull()]
        [string]$ExpectedRootIdentity
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    if (-not [string]::IsNullOrEmpty($ExpectedRootIdentity) -and
        (Get-WindowsFileObjectIdentity -Path $rootPath) -cne $ExpectedRootIdentity) {
        throw 'The private staging identity changed before cleanup.'
    }

    $removeDirectory = {
        param([string]$DirectoryPath)

        if (-not [string]::IsNullOrEmpty($ExpectedRootIdentity) -and
            (Get-WindowsFileObjectIdentity -Path $rootPath) -cne $ExpectedRootIdentity) {
            throw 'The private staging identity changed during cleanup.'
        }
        $directory = Get-Item -LiteralPath $DirectoryPath -Force
        if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-ReparseObjectNoFollow -Item $directory
            return
        }
        if (-not $directory.PSIsContainer) {
            throw 'Private staging cleanup encountered a non-directory traversal object.'
        }
        foreach ($item in @($directory.GetFileSystemInfos())) {
            $isDirectory = ($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparse) {
                Remove-ReparseObjectNoFollow -Item $item
            } elseif ($isDirectory) {
                & $removeDirectory $item.FullName
            } else {
                [System.IO.File]::Delete($item.FullName)
            }
        }
        [System.IO.Directory]::Delete($directory.FullName, $false)
    }

    & $removeDirectory $rootPath
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
        $originalINFName = [System.IO.Path]::GetFileName($originalINF).ToLowerInvariant()
        if ($originalINFName -notmatch '^[a-z0-9][a-z0-9._+~-]*\.inf$') {
            throw "The active $publishedINF original INF basename is not canonical and portable."
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
            OriginalINFName = $originalINFName
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
Reports whether an active package is the policy's authoritative original INF.

.DESCRIPTION
Compares canonical lowercase original INF basenames with ordinal case-sensitive
semantics. Keeping this decision separate from filename discovery prevents an
identically named firmware file in another active package from becoming an
ambiguous or incorrect candidate.
#>
function Test-DriverPackageMatchesPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,

        [Parameter(Mandatory = $true)]
        [object]$Policy
    )

    return ([string]$Package.OriginalINFName -ceq [string]$Policy.SourceINF)
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
        [string]$DestinationPath,

        [AllowNull()]
        [object]$Transaction
    )

    $destinationParent = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if ($null -ne $Transaction) {
        Assert-OutputTransactionBoundary -Transaction $Transaction
        $stagingPrefix = [System.IO.Path]::GetFullPath($Transaction.StagingPath).TrimEnd('\') + '\'
        $fullDestination = [System.IO.Path]::GetFullPath($DestinationPath)
        if (-not $fullDestination.StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A platform firmware destination escaped the protected transaction.'
        }
    }
    [void][System.IO.Directory]::CreateDirectory($destinationParent)
    if ($null -ne $Transaction) {
        Assert-NoReparsePath -Root $Transaction.StagingPath -Child $destinationParent
        Assert-OutputTransactionBoundary -Transaction $Transaction
    }
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
        if ($null -ne $Transaction) {
            Assert-NoReparsePath -Root $Transaction.StagingPath -Child $DestinationPath
            Assert-OutputTransactionBoundary -Transaction $Transaction
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
compiled source filename must resolve exactly once from its authoritative
original INF, with a valid associated catalogue, before any proprietary
payload is copied to staging.
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
            if (-not (Test-DriverPackageMatchesPolicy -Package $package -Policy $policy)) {
                continue
            }
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
                    OriginalINF = $package.OriginalINFName
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
        [string]$StagingRoot,

        [AllowNull()]
        [object]$Transaction
    )

    if (-not $Resolution.Available) {
        return [ordered]@{ included = $false; reason = 'unavailable' }
    }

    $records = @()
    [long]$totalBytes = 0
    foreach ($candidate in $Resolution.Records) {
        $destinationPath = Join-Path $StagingRoot $candidate.Policy.PayloadPath.Replace('/', '\')
        $copied = Copy-VerifiedFirmwareFile -SourcePath $candidate.SourcePath -DestinationPath $destinationPath -Transaction $Transaction
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
                original_inf = $candidate.OriginalINF
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
Uses only network adapters whose structured PnP ancestry descends from the
exact built-in WCN7850 physical radio. It requires PermanentAddress rather
than a current address and fails on ambiguity. Friendly or localised labels
never grant authority. Raw PnP identifiers remain in memory.
#>
function Get-NetAdapterBluetoothEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$BuiltInRadio
    )

    $evidenceByKey = @{}
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)) {
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
        if (-not (Test-PnpDeviceDescendsFrom -CandidateInstanceID $instanceID -AncestorInstanceID $BuiltInRadio.RadioInstanceID)) {
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
Requires exactly one valid local BTHPORT controller-address key and exact
agreement with PermanentAddress evidence whose PnP ancestry reaches the
built-in WCN7850 radio. Invocation with -UseBTHPORTRegistry remains explicit,
but no uncorrelated registry value is accepted. Raw identifiers are neither
written nor displayed.
#>
function Get-BTHPORTBluetoothEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$BuiltInRadio,

        [AllowNull()]
        [object]$CorroboratingEvidence
    )

    if ($null -eq $CorroboratingEvidence -or
        -not (Test-PnpDeviceDescendsFrom -CandidateInstanceID $CorroboratingEvidence.AdapterInstanceID -AncestorInstanceID $BuiltInRadio.RadioInstanceID)) {
        return $null
    }

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

    if ($addresses[0] -cne $CorroboratingEvidence.Address) {
        throw 'The BTHPORT address does not match the built-in radio PermanentAddress evidence.'
    }

    return [pscustomobject][ordered]@{
        Address = $addresses[0]
        Source = 'bthport-registry-operator-confirmed'
        AdapterInstanceID = $CorroboratingEvidence.AdapterInstanceID
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
        [string]$Content,

        [AllowNull()]
        [object]$Transaction
    )

    if ($null -ne $Transaction) {
        Assert-OutputTransactionBoundary -Transaction $Transaction
        $stagingPrefix = [System.IO.Path]::GetFullPath($Transaction.StagingPath).TrimEnd('\') + '\'
        if (-not [System.IO.Path]::GetFullPath($Path).StartsWith($stagingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A manifest destination escaped the protected transaction.'
        }
    }
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
    if ($null -ne $Transaction) {
        Assert-NoReparsePath -Root $Transaction.StagingPath -Child $Path
        Assert-OutputTransactionBoundary -Transaction $Transaction
    }
}

<#
.SYNOPSIS
Creates the exact strict version 2 Windows hand-off manifest envelope.

.DESCRIPTION
Combines already validated collection evidence into the closed JSON shape
consumed by linux-armer. The only exported device identity is a freshly salted
SMBIOS product UUID binding; a Bluetooth adapter instance identifier never
enters this manifest.
#>
function New-HandoffManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CreatedAt,

        [Parameter(Mandatory = $true)]
        [string]$BindingSalt,

        [Parameter(Mandatory = $true)]
        [string]$DeviceBinding,

        [Parameter(Mandatory = $true)]
        [object]$PlatformFirmware,

        [Parameter(Mandatory = $true)]
        [object]$BluetoothPublicAddress
    )

    return [ordered]@{
        schema_version = 2
        kind = 'linux-armer.windows-handoff'
        privacy_classification = 'private-device-bound'
        created_at = $CreatedAt
        collector = [ordered]@{
            name = $script:CollectorName
            version = $script:CollectorVersion
        }
        device = [ordered]@{
            platform_id = 'microsoft-surface-pro-11'
            architecture = 'arm64'
            binding_salt = $BindingSalt
            smbios_product_uuid_binding_sha256 = $DeviceBinding
            wifi_pci_id = '17cb:1107'
        }
        platform_firmware = $PlatformFirmware
        bluetooth_public_address = $BluetoothPublicAddress
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
        [string]$RawBluetoothAdapterInstanceID,

        [AllowNull()]
        [object]$Transaction
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
    foreach ($item in @(Get-ClosedDirectoryEntries -Root $Root -Transaction $Transaction)) {
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
    if ($null -ne $Transaction) {
        Assert-OutputTransactionBoundary -Transaction $Transaction
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
        [object]$Transaction
    )

    Assert-OutputTransactionBoundary -Transaction $Transaction
    if (Test-ImmediateDirectoryEntry -ParentPath $Transaction.ParentPath -Name $Transaction.FinalName) {
        throw 'The Windows hand-off destination appeared during collection; nothing was replaced.'
    }
    [System.IO.Directory]::Move($Transaction.StagingPath, $Transaction.FinalPath)
    Assert-OutputTransactionBoundary -Transaction $Transaction -Published
}

Assert-BindingSelfTest
if ($SelfTest) {
    Assert-PortableFileSelfTest
    Write-Host 'Windows hand-off contract self-test passed.'
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
$builtInBluetoothRadio = $null
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
        $firmwareSection = New-PlatformFirmwareSection -Resolution $resolution -StagingRoot $transaction.StagingPath -Transaction $transaction
        if (-not $firmwareSection.included) {
            Write-Warning 'The complete eleven-file active signed platform firmware set is unavailable.'
        }
    } else {
        $firmwareSection = [ordered]@{ included = $false; reason = 'not-requested' }
    }

    if ($bluetoothRequested) {
        $builtInBluetoothRadio = Get-BuiltInBluetoothRadioEvidence -PresentPnpDevices $deviceEvidence.PresentPnpDevices
        if ($null -eq $builtInBluetoothRadio) {
            $bluetoothEvidence = $null
        } else {
            $permanentBluetoothEvidence = Get-NetAdapterBluetoothEvidence -BuiltInRadio $builtInBluetoothRadio
            if ($UseBTHPORTRegistry) {
                $bluetoothEvidence = Get-BTHPORTBluetoothEvidence -BuiltInRadio $builtInBluetoothRadio -CorroboratingEvidence $permanentBluetoothEvidence
            } else {
                $bluetoothEvidence = $permanentBluetoothEvidence
            }
        }
        if ($null -eq $bluetoothEvidence) {
            $bluetoothSection = [ordered]@{ included = $false; reason = 'unavailable' }
            Write-Warning 'A trusted same-device Bluetooth public address is unavailable.'
        } else {
            $rawAdapterInstanceID = $bluetoothEvidence.AdapterInstanceID
            $bluetoothSection = [ordered]@{
                included = $true
                address = $bluetoothEvidence.Address
                source = $bluetoothEvidence.Source
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

    $createdAt = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $manifest = New-HandoffManifest -CreatedAt $createdAt -BindingSalt $bindingSalt -DeviceBinding $deviceBinding -PlatformFirmware $firmwareSection -BluetoothPublicAddress $bluetoothSection

    $json = ($manifest | ConvertTo-Json -Depth 12) + "`n"
    $manifestPath = Join-Path $transaction.StagingPath $script:ManifestFilename
    Write-NewUTF8File -Path $manifestPath -Content $json -Transaction $transaction
    Assert-ClosedHandoffDirectory -Root $transaction.StagingPath -Manifest $manifest -RawSMBIOSUUID $rawSMBIOSUUID -RawBluetoothAdapterInstanceID $rawAdapterInstanceID -Transaction $transaction

    Publish-HandoffDirectory -Transaction $transaction
    $stagingActive = $false

    Write-Host 'Windows hand-off collection complete.'
    Write-Host "Private output directory: $($transaction.FinalPath)"
    Write-Host 'Import it with linux-armer, then purge every unneeded copy.'
} catch {
    $collectionError = $_
    if ($stagingActive -and $null -ne $transaction) {
        try {
            Remove-ClosedDirectoryNoFollow -Root $transaction.StagingPath -ExpectedRootIdentity $transaction.StagingIdentity
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
    $builtInBluetoothRadio = $null
}
