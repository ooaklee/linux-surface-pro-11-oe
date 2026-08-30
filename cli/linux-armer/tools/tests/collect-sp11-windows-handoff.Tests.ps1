BeforeAll {
    $collectorPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'collect-sp11-windows-handoff.ps1'
    . $collectorPath -SelfTest
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
            '{0}|{1}|{2}|{3}' -f $_.ID, $_.SourceName, $_.PayloadPath, $_.Destination
        })
        $expected = @(
            'gpu-main|qcdxkmsuc8380.mbn|payload/platform-firmware/qcdxkmsuc8380.mbn|lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn',
            'gpu-purwa|qcdxkmsucpurwa.mbn|payload/platform-firmware/qcdxkmsucpurwa.mbn|lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn',
            'adsp-dtb|adsp_dtbs.elf|payload/platform-firmware/adsp_dtbs.elf|lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn',
            'adsp-main|qcadsp8380.mbn|payload/platform-firmware/qcadsp8380.mbn|lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn',
            'adsp-resource|adspr.jsn|payload/platform-firmware/adspr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn',
            'adsp-system|adsps.jsn|payload/platform-firmware/adsps.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn',
            'adsp-user|adspua.jsn|payload/platform-firmware/adspua.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn',
            'battery-manager|battmgr.jsn|payload/platform-firmware/battmgr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn',
            'cdsp-dtb|cdsp_dtbs.elf|payload/platform-firmware/cdsp_dtbs.elf|lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn',
            'cdsp-main|qccdsp8380.mbn|payload/platform-firmware/qccdsp8380.mbn|lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn',
            'cdsp-resource|cdspr.jsn|payload/platform-firmware/cdspr.jsn|lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn'
        )

        $actual | Should -HaveCount 11
        (Compare-Object -ReferenceObject $expected -DifferenceObject $actual -SyncWindow 0) | Should -BeNullOrEmpty
    }

    It 'canonicalises a private adapter identity before deriving its binding' {
        $actual = ConvertTo-CanonicalAdapterInstanceID -Value ' bth\ms_bthpan\7&12345678&0&2 '
        $actual | Should -BeExactly 'BTH\MS_BTHPAN\7&12345678&0&2'
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
}
