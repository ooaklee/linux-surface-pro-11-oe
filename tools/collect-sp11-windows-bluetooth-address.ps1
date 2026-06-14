param()

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Format-MacAddress {
    param(
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $raw = ($Value -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($raw -match '^[0-9A-F]{12}$') {
        return ($raw -replace '(.{2})(?=.)', '$1:')
    }

    return $Value
}

Write-Host "Surface Pro 11 Bluetooth address candidates"
Write-Host "Privacy note: this output includes hardware addresses. Do not share it publicly without redaction."
Write-Host ""

$keysPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys'
$registryCandidates = @()

Get-ChildItem $keysPath -ErrorAction SilentlyContinue |
    ForEach-Object {
        $raw = $_.PSChildName.ToUpper()
        if ($raw -match '^[0-9A-F]{12}$') {
            $registryCandidates += [pscustomobject]@{
                Source = 'BTHPORT registry key'
                MacAddress = Format-MacAddress $raw
            }
        }
    }

Write-Host "## BTHPORT registry candidates"
if ($registryCandidates.Count -gt 0) {
    $registryCandidates | Format-Table -AutoSize
} else {
    Write-Host "No registry candidates found. Run PowerShell as Administrator, or compare the adapter list below."
}

Write-Host ""
Write-Host "## Bluetooth and Qualcomm/FastConnect adapters"
$adapters = Get-NetAdapter -IncludeHidden |
    Where-Object {
        $_.Name -match 'Bluetooth' -or
        $_.InterfaceDescription -match 'Bluetooth|Qualcomm|FastConnect|WCN'
    } |
    Sort-Object Name |
    Select-Object Name,
                  InterfaceDescription,
                  Status,
                  @{Name = 'MacAddress'; Expression = { Format-MacAddress $_.MacAddress } },
                  @{Name = 'PermanentAddress'; Expression = { Format-MacAddress $_.PermanentAddress } }

if ($adapters) {
    $adapters | Format-List
} else {
    Write-Host "No matching Bluetooth, Qualcomm, FastConnect, or WCN adapters found."
}

Write-Host ""
Write-Host "Use the Bluetooth adapter PermanentAddress when present."
Write-Host "Do not use a Wi-Fi adapter address unless Windows confirms it is the Bluetooth radio address."
