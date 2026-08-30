package handoff

// FirmwarePolicy is one immutable source, payload, and destination mapping in
// the complete Surface Pro 11 Windows hand-off set.
type FirmwarePolicy struct {
	// ID is the stable contract identifier used to detect substitutions.
	ID string
	// SourceName is the exact filename selected from the Windows DriverStore.
	SourceName string
	// PayloadPath is the only permitted portable location in a hand-off bundle.
	PayloadPath string
	// Destination is the only permitted root-relative Linux installation path.
	Destination string
}

// firmwarePolicyTable is the immutable canonical order and complete allow-list
// for Windows-derived Surface Pro 11 platform firmware.
var firmwarePolicyTable = [...]FirmwarePolicy{
	{
		ID:          "gpu-main",
		SourceName:  "qcdxkmsuc8380.mbn",
		PayloadPath: "payload/platform-firmware/qcdxkmsuc8380.mbn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn",
	},
	{
		ID:          "gpu-purwa",
		SourceName:  "qcdxkmsucpurwa.mbn",
		PayloadPath: "payload/platform-firmware/qcdxkmsucpurwa.mbn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn",
	},
	{
		ID:          "adsp-dtb",
		SourceName:  "adsp_dtbs.elf",
		PayloadPath: "payload/platform-firmware/adsp_dtbs.elf",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn",
	},
	{
		ID:          "adsp-main",
		SourceName:  "qcadsp8380.mbn",
		PayloadPath: "payload/platform-firmware/qcadsp8380.mbn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn",
	},
	{
		ID:          "adsp-resource",
		SourceName:  "adspr.jsn",
		PayloadPath: "payload/platform-firmware/adspr.jsn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn",
	},
	{
		ID:          "adsp-system",
		SourceName:  "adsps.jsn",
		PayloadPath: "payload/platform-firmware/adsps.jsn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn",
	},
	{
		ID:          "adsp-user",
		SourceName:  "adspua.jsn",
		PayloadPath: "payload/platform-firmware/adspua.jsn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn",
	},
	{
		ID:          "battery-manager",
		SourceName:  "battmgr.jsn",
		PayloadPath: "payload/platform-firmware/battmgr.jsn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn",
	},
	{
		ID:          "cdsp-dtb",
		SourceName:  "cdsp_dtbs.elf",
		PayloadPath: "payload/platform-firmware/cdsp_dtbs.elf",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn",
	},
	{
		ID:          "cdsp-main",
		SourceName:  "qccdsp8380.mbn",
		PayloadPath: "payload/platform-firmware/qccdsp8380.mbn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn",
	},
	{
		ID:          "cdsp-resource",
		SourceName:  "cdspr.jsn",
		PayloadPath: "payload/platform-firmware/cdspr.jsn",
		Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn",
	},
}

// FirmwarePolicies returns a defensive copy of the canonical eleven-file
// policy so callers cannot mutate validation authority.
func FirmwarePolicies() []FirmwarePolicy {
	policies := make([]FirmwarePolicy, len(firmwarePolicyTable))
	copy(policies, firmwarePolicyTable[:])
	return policies
}
