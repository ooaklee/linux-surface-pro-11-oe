BeforeAll {
    $collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'collect-sp11-windows-handoff.ps1'
    . $collectorPath -SelfTest

    <# Supplies the fail-closed PnP boundary that individual Pester cases mock. #>
    function global:Get-PnpDeviceProperty {
        [CmdletBinding()]
        param(
            [string]$InstanceId,
            [string]$KeyName
        )
        throw 'The PnP property test boundary was not mocked.'
    }

    <# Supplies the fail-closed network-adapter boundary that Pester cases mock. #>
    function global:Get-NetAdapter {
        [CmdletBinding()]
        param(
            [switch]$IncludeHidden
        )
        throw 'The network-adapter test boundary was not mocked.'
    }
}

AfterAll {
    Remove-Item -LiteralPath Function:\Get-PnpDeviceProperty -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-NetAdapter -ErrorAction SilentlyContinue
    Remove-Variable -Name identityDriftParentPath -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name identityDriftParentIdentity -Scope Script -ErrorAction SilentlyContinue
}

Describe 'Surface Pro 11 Windows hand-off collector contract' {
    It 'passes its pinned binding, copy and BOM-free encoding self-tests' {
        { & $collectorPath -SelfTest } | Should -Not -Throw
    }

    It 'returns one fresh typed 32-byte binding salt' {
        $salt = New-BindingSalt
        try {
            $salt.GetType().FullName | Should -BeExactly 'System.Byte[]'
            $salt | Should -HaveCount 32
            @($salt | Where-Object { $_ -ne 0 }).Count | Should -BeGreaterThan 0
        } finally {
            [Array]::Clear($salt, 0, $salt.Length)
        }
    }

    It 'keeps the complete firmware policy in canonical Go-contract order' {
        $actual = @(Get-PlatformFirmwarePolicy | ForEach-Object {
            '{0}|{1}|{2}|{3}|{4}' -f $_.ID, $_.SourceName, $_.SourceINF, $_.PayloadPath, $_.Destination
        })
        $expected = @(
            'gpu-main|qcdxkmsuc8380.mbn|qcdx8380.inf|payload/platform-firmware/qcdxkmsuc8380.mbn|lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn',
            'gpu-purwa|qcdxkmsucpurwa.mbn|qcdx8380.inf|payload/platform-firmware/qcdxkmsucpurwa.mbn|lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn',
            'adsp-dtb|adsp_dtbs.elf|surfacepro_ext_adsp8380.inf|payload/platform-firmware/adsp_dtbs.elf|lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn',
            'adsp-main|qcadsp8380.mbn|surfacepro_ext_adsp8380.inf|payload/platform-firmware/qcadsp8380.mbn|lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn',
            'adsp-resource|adspr.jsn|surfacepro_ext_adsp8380.inf|payload/platform-firmware/adspr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn',
            'adsp-system|adsps.jsn|surfacepro_ext_adsp8380.inf|payload/platform-firmware/adsps.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn',
            'adsp-user|adspua.jsn|surfacepro_ext_adsp8380.inf|payload/platform-firmware/adspua.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn',
            'battery-manager|battmgr.jsn|surfacepro_ext_adsp8380.inf|payload/platform-firmware/battmgr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn',
            'cdsp-dtb|cdsp_dtbs.elf|qcnspmcdm_ext_cdsp8380.inf|payload/platform-firmware/cdsp_dtbs.elf|lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn',
            'cdsp-main|qccdsp8380.mbn|qcnspmcdm_ext_cdsp8380.inf|payload/platform-firmware/qccdsp8380.mbn|lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn',
            'cdsp-resource|cdspr.jsn|qcnspmcdm_ext_cdsp8380.inf|payload/platform-firmware/cdspr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn'
        )

        $actual | Should -HaveCount 11
        (Compare-Object -ReferenceObject $expected -DifferenceObject $actual -SyncWindow 0) | Should -BeNullOrEmpty
    }

    It 'canonicalises a private adapter identity as in-memory collection evidence' {
        $actual = ConvertTo-CanonicalAdapterInstanceID -Value ' bth\ms_bthpan\7&12345678&0&2 '
        $actual | Should -BeExactly 'BTH\MS_BTHPAN\7&12345678&0&2'
    }

    It 'accepts only the exact built-in WCN7850 radio on its ACPI transport' {
        $radioID = 'QCA_SHB\UART_H4_HMT\1'
        $transportID = 'ACPI\QCOM0D04\0'
        $script:pnpPropertyFixture = @{
            ($radioID + '|DEVPKEY_Device_HardwareIds') = @('QCA_SHB\UART_H4_HMT')
            ($radioID + '|DEVPKEY_Device_Parent') = $transportID
            ($transportID + '|DEVPKEY_Device_HardwareIds') = @('ACPI\QCOM0D04')
        }
        Mock Get-PnpDeviceProperty {
            [pscustomobject]@{ KeyName = $KeyName; Data = $script:pnpPropertyFixture[$InstanceId + '|' + $KeyName] }
        }
        $present = @([pscustomobject]@{ Class = 'Bluetooth'; InstanceId = $radioID; FriendlyName = 'localised label' })

        $actual = Get-BuiltInBluetoothRadioEvidence -PresentPnpDevices $present

        $actual.RadioInstanceID | Should -BeExactly $radioID
        $actual.TransportInstanceID | Should -BeExactly $transportID
    }

    It 'rejects an external physical radio even when the built-in radio is present' {
        $present = @(
            [pscustomobject]@{ Class = 'Bluetooth'; InstanceId = 'QCA_SHB\UART_H4_HMT\1'; FriendlyName = 'built in' },
            [pscustomobject]@{ Class = 'Bluetooth'; InstanceId = 'USB\VID_1234&PID_5678\1'; FriendlyName = 'external' }
        )

        { Get-BuiltInBluetoothRadioEvidence -PresentPnpDevices $present } | Should -Throw '*external or ambiguous*'
    }

    It 'rejects an unknown physical Bluetooth bus rather than ignoring it' {
        $present = @(
            [pscustomobject]@{ Class = 'Bluetooth'; InstanceId = 'QCA_SHB\UART_H4_HMT\1'; FriendlyName = 'built in' },
            [pscustomobject]@{ Class = 'Bluetooth'; InstanceId = 'HID\VID_1234&PID_5678\1'; FriendlyName = 'unexpected physical bus' }
        )

        { Get-BuiltInBluetoothRadioEvidence -PresentPnpDevices $present } | Should -Throw '*external or ambiguous*'
    }

    It 'correlates PermanentAddress through the exact built-in radio ancestry' {
        $radioID = 'QCA_SHB\UART_H4_HMT\1'
        $adapterID = 'BTH\MS_BTHPAN\7&12345678&0&2'
        $script:pnpPropertyFixture = @{
            ($adapterID + '|DEVPKEY_Device_Parent') = $radioID
        }
        Mock Get-PnpDeviceProperty {
            [pscustomobject]@{ KeyName = $KeyName; Data = $script:pnpPropertyFixture[$InstanceId + '|' + $KeyName] }
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name = 'Bluetooth Network Connection'
                InterfaceDescription = 'Bluetooth Device (Personal Area Network)'
                PermanentAddress = '10-20-30-40-50-60'
                PnPDeviceID = $adapterID
            }
        }

        $actual = Get-NetAdapterBluetoothEvidence -BuiltInRadio ([pscustomobject]@{ RadioInstanceID = $radioID })

        $actual.Address | Should -BeExactly '10:20:30:40:50:60'
        $actual.AdapterInstanceID | Should -BeExactly $adapterID
    }

    It 'rejects a singleton PermanentAddress belonging to an external radio' {
        $builtInRadioID = 'QCA_SHB\UART_H4_HMT\1'
        $adapterID = 'BTH\MS_BTHPAN\7&12345678&0&2'
        $script:pnpPropertyFixture = @{
            ($adapterID + '|DEVPKEY_Device_Parent') = 'USB\VID_1234&PID_5678\1'
        }
        Mock Get-PnpDeviceProperty {
            $data = $script:pnpPropertyFixture[$InstanceId + '|' + $KeyName]
            if ($null -eq $data) {
                throw 'fixture chain ended'
            }
            [pscustomobject]@{ KeyName = $KeyName; Data = $data }
        }
        Mock Get-NetAdapter {
            [pscustomobject]@{
                Name = 'Bluetooth Network Connection'
                InterfaceDescription = 'Bluetooth Device (Personal Area Network)'
                PermanentAddress = '10-20-30-40-50-60'
                PnPDeviceID = $adapterID
            }
        }

        $actual = Get-NetAdapterBluetoothEvidence -BuiltInRadio ([pscustomobject]@{ RadioInstanceID = $builtInRadioID })

        $actual | Should -BeNullOrEmpty
    }

    It 'rejects an uncorrelated BTHPORT controller address' {
        $builtInRadio = [pscustomobject]@{ RadioInstanceID = 'QCA_SHB\UART_H4_HMT\1' }

        $actual = Get-BTHPORTBluetoothEvidence -BuiltInRadio $builtInRadio -CorroboratingEvidence $null

        $actual | Should -BeNullOrEmpty
    }

    It 'uses the authoritative original INF to disambiguate duplicate source names' {
        $policy = @(Get-PlatformFirmwarePolicy | Where-Object { $_.ID -ceq 'cdsp-dtb' })[0]
        $packages = @(
            [pscustomobject]@{ OriginalINFName = 'qcsubsys_ext_cdsp8380.inf' },
            [pscustomobject]@{ OriginalINFName = 'qcnspmcdm_ext_cdsp8380.inf' }
        )

        $matching = @($packages | Where-Object { Test-DriverPackageMatchesPolicy -Package $_ -Policy $policy })

        $matching | Should -HaveCount 1
        $matching[0].OriginalINFName | Should -BeExactly 'qcnspmcdm_ext_cdsp8380.inf'
    }

    It 'emits the exact strict version 2 manifest shape' {
        $firmware = [ordered]@{
            included = $true
            files = @([ordered]@{
                id = 'gpu-main'
                source_name = 'qcdxkmsuc8380.mbn'
                payload_path = 'payload/platform-firmware/qcdxkmsuc8380.mbn'
                destination = 'lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn'
                size_bytes = 3
                sha256 = ('03' * 32)
                windows_source = [ordered]@{
                    driver_store_path = 'Windows/System32/DriverStore/FileRepository/qcdx8380.inf_arm64_fixture/qcdxkmsuc8380.mbn'
                    published_inf = 'oem42.inf'
                    original_inf = 'qcdx8380.inf'
                    driver_version = '1.2.3.4'
                    catalogue_sha256 = ('04' * 32)
                    catalogue_signature = 'valid'
                }
            })
        }
        $manifest = New-HandoffManifest `
            -CreatedAt '2026-08-30T12:00:00Z' `
            -BindingSalt ('01' * 32) `
            -DeviceBinding ('02' * 32) `
            -PlatformFirmware $firmware `
            -BluetoothPublicAddress ([ordered]@{ included = $true; address = '10:20:30:40:50:60'; source = 'net-adapter-permanent-address' })

        ($manifest.Keys -join '|') | Should -BeExactly 'schema_version|kind|privacy_classification|created_at|collector|device|platform_firmware|bluetooth_public_address'
        $manifest.schema_version | Should -Be 2
        $manifest.collector.version | Should -BeExactly '2.0.0'
        ($manifest.platform_firmware.files[0].windows_source.Keys -join '|') | Should -BeExactly 'driver_store_path|published_inf|original_inf|driver_version|catalogue_sha256|catalogue_signature'
        $manifest.platform_firmware.files[0].windows_source.original_inf | Should -BeExactly 'qcdx8380.inf'
        $json = $manifest | ConvertTo-Json -Depth 12
        $json | Should -Not -Match 'adapter_instance_id_binding_sha256'
    }

    It 'carries the resolved original INF into emitted firmware provenance' {
        $sourcePath = Join-Path $TestDrive 'qcdxkmsuc8380.mbn'
        [System.IO.File]::WriteAllBytes($sourcePath, [byte[]]@(1, 2, 3))
        $policy = @(Get-PlatformFirmwarePolicy | Where-Object { $_.ID -ceq 'gpu-main' })[0]
        $resolution = [pscustomobject][ordered]@{
            Available = $true
            Records = @([pscustomobject][ordered]@{
                Policy = $policy
                SourcePath = $sourcePath
                DriverStorePath = 'Windows/System32/DriverStore/FileRepository/qcdx8380.inf_arm64_fixture/qcdxkmsuc8380.mbn'
                PublishedINF = 'oem42.inf'
                OriginalINF = 'qcdx8380.inf'
                DriverVersion = '1.2.3.4'
                CatalogueSHA256 = ('04' * 32)
                CatalogueSignature = 'valid'
            })
        }

        $section = New-PlatformFirmwareSection -Resolution $resolution -StagingRoot (Join-Path $TestDrive 'staging')

        $section.files | Should -HaveCount 1
        $section.files[0].windows_source.original_inf | Should -BeExactly 'qcdx8380.inf'
    }

    It 'rejects malformed adapter identities without echoing them' {
        foreach ($instanceID in @('BTH\\VALUE', 'BTH/DEVICE/VALUE', "BTH\DEVICE\CAF$([char]0x00E9)")) {
            $message = ''
            try {
                [void](ConvertTo-CanonicalAdapterInstanceID -Value $instanceID)
            } catch {
                $message = $_.Exception.Message
            }
            $message | Should -Not -BeNullOrEmpty
            $message | Should -Not -Match ([regex]::Escape($instanceID))
        }
    }

    It 'rejects Bluetooth placeholder and multicast addresses without echoing them' {
        foreach ($address in @('00:00:00:00:5A:AD', 'AA:BB:CC:DD:EE:FF', '01:20:30:40:50:60')) {
            $message = ''
            try {
                [void](ConvertTo-CanonicalBluetoothAddress -Value $address)
            } catch {
                $message = $_.Exception.Message
            }
            $message | Should -Not -BeNullOrEmpty
            $message | Should -Not -Match ([regex]::Escape($address))
        }
    }

    It 'contains no known Windows Wi-Fi firmware payload mapping' {
        $source = [System.IO.File]::ReadAllText($collectorPath)
        foreach ($forbidden in @('board-2.bin', 'amss.bin', 'm3.bin', 'regdb.bin', 'ath12k', 'WCN7850/hw2.0')) {
            $source.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) | Should -Be -1
        }
    }

    It 'never uses provider-recursive deletion for private staging cleanup' {
        $source = [System.IO.File]::ReadAllText($collectorPath)
        $source | Should -Not -Match 'Remove-Item[^\r\n]*-Recurse'
        $source | Should -Match 'Remove-ClosedDirectoryNoFollow'
    }

    It 'accepts an exact protected parent and allocates one identity-bound transaction' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'The protected NTFS transaction contract is Windows-specific.'
            return
        }

        $commonApplicationData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
        $privateParent = Join-Path $commonApplicationData ('linux-armer-pester-' + [guid]::NewGuid().ToString('N'))
        $transaction = $null
        [void][System.IO.Directory]::CreateDirectory($privateParent)
        try {
            Set-PrivateDirectoryACL -Path $privateParent
            $expectedParentIdentity = Get-WindowsFileObjectIdentity -Path $privateParent

            (Assert-SecureOutputPath -ParentPath $privateParent) | Should -BeExactly $expectedParentIdentity
            $transaction = New-OutputTransaction -RequestedPath (Join-Path $privateParent 'handoff')
            { Assert-OutputTransactionBoundary -Transaction $transaction } | Should -Not -Throw
            $transaction.ParentIdentity | Should -BeExactly $expectedParentIdentity
            [System.IO.Directory]::Exists($transaction.StagingPath) | Should -BeTrue
            [System.IO.Directory]::Exists($transaction.FinalPath) | Should -BeFalse
        } finally {
            if ($null -ne $transaction -and [System.IO.Directory]::Exists($transaction.StagingPath)) {
                Remove-ClosedDirectoryNoFollow -Root $transaction.StagingPath -ExpectedRootIdentity $transaction.StagingIdentity
            }
            if ([System.IO.Directory]::Exists($privateParent)) {
                $parentIdentity = Get-WindowsFileObjectIdentity -Path $privateParent
                Remove-ClosedDirectoryNoFollow -Root $privateParent -ExpectedRootIdentity $parentIdentity
            }
        }
    }

    It 'rejects an untrusted access rule on an otherwise protected parent' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'Windows directory access-control rules are unavailable on this host.'
            return
        }

        $privateParent = Join-Path $TestDrive 'private-untrusted-rule'
        [void][System.IO.Directory]::CreateDirectory($privateParent)
        Set-PrivateDirectoryACL -Path $privateParent
        $security = [System.IO.Directory]::GetAccessControl($privateParent)
        $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $users,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$security.AddAccessRule($rule)
        [System.IO.Directory]::SetAccessControl($privateParent, $security)

        { Assert-PrivateDirectoryACL -Path $privateParent } | Should -Throw '*only explicit inheritable full-control entries*'
    }

    It 'rejects a private parent whose DACL still inherits access rules' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'Windows directory access-control rules are unavailable on this host.'
            return
        }

        $privateParent = Join-Path $TestDrive 'private-inherited-rules'
        [void][System.IO.Directory]::CreateDirectory($privateParent)
        Set-PrivateDirectoryACL -Path $privateParent
        $security = [System.IO.Directory]::GetAccessControl($privateParent)
        $security.SetAccessRuleProtection($false, $true)
        [System.IO.Directory]::SetAccessControl($privateParent, $security)

        { Assert-PrivateDirectoryACL -Path $privateParent } | Should -Throw '*inheritance disabled*'
    }

    It 'rejects a private parent owned by the interactive administrator account' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'Windows directory ownership is unavailable on this host.'
            return
        }

        $privateParent = Join-Path $TestDrive 'private-untrusted-owner'
        [void][System.IO.Directory]::CreateDirectory($privateParent)
        Set-PrivateDirectoryACL -Path $privateParent
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $security = [System.IO.Directory]::GetAccessControl($privateParent)
            $security.SetOwner($identity.User)
            [System.IO.Directory]::SetAccessControl($privateParent, $security)
        } finally {
            $identity.Dispose()
        }

        { Assert-PrivateDirectoryACL -Path $privateParent } | Should -Throw '*owner must be Local System or the built-in Administrators group*'
    }

    It 'rejects a retained staging identity that changes before a sensitive boundary' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'Windows file-object identities are unavailable on this host.'
            return
        }

        $privateParent = Join-Path $TestDrive 'private-identity-drift'
        $stagingPath = Join-Path $privateParent '.linux-armer-collecting-fixture'
        [void][System.IO.Directory]::CreateDirectory($stagingPath)
        Set-PrivateDirectoryACL -Path $privateParent
        Set-PrivateDirectoryACL -Path $stagingPath
        $parentIdentity = Get-WindowsFileObjectIdentity -Path $privateParent
        $stagingIdentity = Get-WindowsFileObjectIdentity -Path $stagingPath
        $script:identityDriftParentPath = $privateParent
        $script:identityDriftParentIdentity = $parentIdentity
        $transaction = [pscustomobject][ordered]@{
            ParentPath = $privateParent
            ParentIdentity = $parentIdentity
            FinalPath = Join-Path $privateParent 'handoff'
            StagingPath = $stagingPath
            StagingIdentity = $stagingIdentity
        }
        Mock Get-WindowsFileObjectIdentity {
            if ([System.IO.Path]::GetFullPath($Path) -ieq [System.IO.Path]::GetFullPath($script:identityDriftParentPath)) {
                return $script:identityDriftParentIdentity
            }
            return 'replacement-staging-identity'
        }

        { Assert-OutputTransactionBoundary -Transaction $transaction } | Should -Throw '*transaction object changed*'
    }

    It 'refuses to replace a destination that appears before publication' {
        if ($env:OS -cne 'Windows_NT') {
            Set-ItResult -Skipped -Because 'The no-replace publication transaction is Windows-specific.'
            return
        }

        $privateParent = Join-Path $TestDrive 'private-publication-collision'
        $stagingPath = Join-Path $privateParent '.linux-armer-collecting-fixture'
        $finalPath = Join-Path $privateParent 'handoff'
        [void][System.IO.Directory]::CreateDirectory($stagingPath)
        Set-PrivateDirectoryACL -Path $privateParent
        Set-PrivateDirectoryACL -Path $stagingPath
        $transaction = [pscustomobject][ordered]@{
            ParentPath = $privateParent
            ParentIdentity = Get-WindowsFileObjectIdentity -Path $privateParent
            FinalPath = $finalPath
            FinalName = 'handoff'
            StagingPath = $stagingPath
            StagingIdentity = Get-WindowsFileObjectIdentity -Path $stagingPath
        }
        [void][System.IO.Directory]::CreateDirectory($finalPath)
        $sentinelPath = Join-Path $finalPath 'sentinel.txt'
        [System.IO.File]::WriteAllText($sentinelPath, 'must remain')

        { Publish-HandoffDirectory -Transaction $transaction } | Should -Throw '*destination appeared*'

        [System.IO.Directory]::Exists($stagingPath) | Should -BeTrue
        [System.IO.File]::ReadAllText($sentinelPath) | Should -BeExactly 'must remain'
    }

    It 'does not follow an injected reparse directory during cleanup' {
        $transactionRoot = Join-Path $TestDrive 'transaction-cleanup'
        $outsideRoot = Join-Path $TestDrive 'outside-sentinel'
        [void][System.IO.Directory]::CreateDirectory($transactionRoot)
        [void][System.IO.Directory]::CreateDirectory($outsideRoot)
        $sentinelPath = Join-Path $outsideRoot 'sentinel.txt'
        [System.IO.File]::WriteAllText($sentinelPath, 'must survive')
        $linkPath = Join-Path $transactionRoot 'injected-link'
        try {
            if ($env:OS -ceq 'Windows_NT') {
                [void](New-Item -ItemType Junction -Path $linkPath -Target $outsideRoot -ErrorAction Stop)
            } else {
                [void](New-Item -ItemType SymbolicLink -Path $linkPath -Target $outsideRoot -ErrorAction Stop)
            }
        } catch {
            Set-ItResult -Skipped -Because 'This host cannot create the reparse object needed by the sentinel test.'
            return
        }

        Remove-ClosedDirectoryNoFollow -Root $transactionRoot

        [System.IO.Directory]::Exists($transactionRoot) | Should -BeFalse
        [System.IO.File]::ReadAllText($sentinelPath) | Should -BeExactly 'must survive'
    }

    It 'refuses cleanup when the retained transaction identity changed' {
        $transactionRoot = Join-Path $TestDrive 'identity-mismatch'
        [void][System.IO.Directory]::CreateDirectory($transactionRoot)
        $sentinelPath = Join-Path $transactionRoot 'sentinel.txt'
        [System.IO.File]::WriteAllText($sentinelPath, 'must remain')
        Mock Get-WindowsFileObjectIdentity { 'replacement-identity' }

        { Remove-ClosedDirectoryNoFollow -Root $transactionRoot -ExpectedRootIdentity 'original-identity' } | Should -Throw '*identity changed*'

        [System.IO.File]::ReadAllText($sentinelPath) | Should -BeExactly 'must remain'
    }
}
