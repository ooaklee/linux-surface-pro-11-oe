package handoff

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

// TestGoldenContract validates the human-readable fixture, exact binding
// derivation, stable writer, and deliberately non-sensitive summary.
func TestGoldenContract(t *testing.T) {
	t.Parallel()

	contract := decodeGoldenContract(t)
	if len(contract.PlatformFirmware.Files) != len(firmwarePolicyTable) {
		t.Fatalf("firmware file count = %d, want %d", len(contract.PlatformFirmware.Files), len(firmwarePolicyTable))
	}
	binding, err := DeriveDeviceBinding(
		contract.Device.BindingSalt,
		"12345678-1234-5678-9abc-def012345678",
	)
	if err != nil {
		t.Fatal(err)
	}
	if binding != contract.Device.SMBIOSProductUUIDBindingSHA256 {
		t.Fatalf("derived binding = %s, want fixture binding", binding)
	}
	const adapterInstanceID = `BTH\MS_BTHPAN\7&12345678&0&2`
	adapterBinding, err := DeriveBluetoothAdapterBinding(contract.Device.BindingSalt, adapterInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	if adapterBinding != *contract.BluetoothPublicAddress.AdapterInstanceIDBindingSHA256 {
		t.Fatalf("derived Bluetooth adapter binding = %s, want fixture binding", adapterBinding)
	}

	var written bytes.Buffer
	if err := contract.WriteJSON(&written); err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(bytes.NewReader(written.Bytes())); err != nil {
		t.Fatalf("Decode(WriteJSON()) error = %v", err)
	}
	if bytes.Contains(written.Bytes(), []byte("\\u003c")) {
		t.Fatalf("WriteJSON() unexpectedly escaped safe text: %s", written.Bytes())
	}

	privateAddress := string(*contract.BluetoothPublicAddress.Address)
	summary, err := json.Marshal(contract.Summary())
	if err != nil {
		t.Fatal(err)
	}
	for _, privateValue := range []string{
		privateAddress,
		adapterInstanceID,
		contract.Device.BindingSalt,
		contract.Device.SMBIOSProductUUIDBindingSHA256,
		*contract.BluetoothPublicAddress.AdapterInstanceIDBindingSHA256,
	} {
		if strings.Contains(string(summary), privateValue) {
			t.Fatalf("summary disclosed private value: %s", summary)
		}
	}
	formatted := fmt.Sprintf("%s %#v", *contract.BluetoothPublicAddress.Address, *contract.BluetoothPublicAddress.Address)
	if strings.Contains(formatted, privateAddress) || !strings.Contains(formatted, "<redacted>") {
		t.Fatalf("Bluetooth address formatting was not redacted: %s", formatted)
	}
}

// TestDeriveBluetoothAdapterBinding pins its domain-separated vector, proves
// fresh salts prevent linkability, and enforces the PowerShell canonical form.
func TestDeriveBluetoothAdapterBinding(t *testing.T) {
	t.Parallel()

	const instanceID = `BTH\MS_BTHPAN\7&12345678&0&2`
	firstSalt := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	first, err := DeriveBluetoothAdapterBinding(firstSalt, instanceID)
	if err != nil {
		t.Fatal(err)
	}
	if first != "1c160571108944ea6d3bd4f45f65133cea74a9a4097d3f75eb315ac138a99f70" {
		t.Fatalf("DeriveBluetoothAdapterBinding() = %s, want pinned vector", first)
	}
	secondSalt := "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
	second, err := DeriveBluetoothAdapterBinding(secondSalt, instanceID)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("separate salts produced a linkable Bluetooth adapter binding")
	}

	for name, candidate := range map[string]string{
		"lowercase":       `BTH\MS_BTHPAN\lowercase`,
		"leading space":   ` BTH\MS_BTHPAN\VALUE`,
		"trailing space":  `BTH\MS_BTHPAN\VALUE `,
		"no separator":    `BTH`,
		"empty component": `BTH\\VALUE`,
		"forward slash":   `BTH/MS_BTHPAN/VALUE`,
		"non-ASCII":       `BTH\MS_BTHPAN\CAFÉ`,
		"control":         "BTH\\MS_BTHPAN\\VALUE\n",
	} {
		name, candidate := name, candidate
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := DeriveBluetoothAdapterBinding(firstSalt, candidate)
			if err == nil {
				t.Fatal("DeriveBluetoothAdapterBinding() accepted non-canonical input")
			}
			if strings.Contains(err.Error(), candidate) {
				t.Fatalf("derivation error disclosed adapter instance ID: %v", err)
			}
		})
	}
}

// TestFirmwarePoliciesMatchExactContract pins every ID, source name, payload
// path, destination, and canonical order in the compiled eleven-file set.
func TestFirmwarePoliciesMatchExactContract(t *testing.T) {
	t.Parallel()

	expected := []FirmwarePolicy{
		{ID: "gpu-main", SourceName: "qcdxkmsuc8380.mbn", PayloadPath: "payload/platform-firmware/qcdxkmsuc8380.mbn", Destination: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn"},
		{ID: "gpu-purwa", SourceName: "qcdxkmsucpurwa.mbn", PayloadPath: "payload/platform-firmware/qcdxkmsucpurwa.mbn", Destination: "lib/firmware/qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn"},
		{ID: "adsp-dtb", SourceName: "adsp_dtbs.elf", PayloadPath: "payload/platform-firmware/adsp_dtbs.elf", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn"},
		{ID: "adsp-main", SourceName: "qcadsp8380.mbn", PayloadPath: "payload/platform-firmware/qcadsp8380.mbn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn"},
		{ID: "adsp-resource", SourceName: "adspr.jsn", PayloadPath: "payload/platform-firmware/adspr.jsn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspr.jsn"},
		{ID: "adsp-system", SourceName: "adsps.jsn", PayloadPath: "payload/platform-firmware/adsps.jsn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adsps.jsn"},
		{ID: "adsp-user", SourceName: "adspua.jsn", PayloadPath: "payload/platform-firmware/adspua.jsn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/adspua.jsn"},
		{ID: "battery-manager", SourceName: "battmgr.jsn", PayloadPath: "payload/platform-firmware/battmgr.jsn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/battmgr.jsn"},
		{ID: "cdsp-dtb", SourceName: "cdsp_dtbs.elf", PayloadPath: "payload/platform-firmware/cdsp_dtbs.elf", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn"},
		{ID: "cdsp-main", SourceName: "qccdsp8380.mbn", PayloadPath: "payload/platform-firmware/qccdsp8380.mbn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn"},
		{ID: "cdsp-resource", SourceName: "cdspr.jsn", PayloadPath: "payload/platform-firmware/cdspr.jsn", Destination: "lib/firmware/qcom/x1e80100/microsoft/Denali/cdspr.jsn"},
	}
	if got := FirmwarePolicies(); !reflect.DeepEqual(got, expected) {
		t.Fatalf("FirmwarePolicies() = %#v, want %#v", got, expected)
	}
	mutable := FirmwarePolicies()
	mutable[0].ID = "changed"
	if FirmwarePolicies()[0].ID != expected[0].ID {
		t.Fatal("FirmwarePolicies() exposed mutable validation authority")
	}
}

// TestDecodeRejectsStrictJSONViolations checks all structural ambiguity and
// input-boundary gates before typed semantic validation.
func TestDecodeRejectsStrictJSONViolations(t *testing.T) {
	t.Parallel()

	golden := string(readGoldenDocument(t))
	testCases := []struct {
		name     string
		document []byte
		message  string
	}{
		{name: "unknown field", document: []byte(replaceOnce(t, golden, `"created_at":`, `"unexpected":true,"created_at":`)), message: "unknown or mis-cased"},
		{name: "duplicate field", document: []byte(replaceOnce(t, golden, `"kind": "linux-armer.windows-handoff"`, `"kind":"linux-armer.windows-handoff","kind":"other"`)), message: "duplicate field"},
		{name: "mis-cased field", document: []byte(replaceOnce(t, golden, `"privacy_classification"`, `"Privacy_Classification"`)), message: "unknown or mis-cased"},
		{name: "retired adapter digest field", document: []byte(replaceOnce(t, golden, `"adapter_instance_id_binding_sha256"`, `"adapter_instance_id_sha256"`)), message: "unknown or mis-cased"},
		{name: "missing required field", document: []byte(replaceOnce(t, golden, "  \"privacy_classification\": \"private-device-bound\",\n", ``)), message: "required field"},
		{name: "null top-level object", document: []byte(`null`), message: "must not be null"},
		{name: "null collector", document: []byte(replaceObjectWithNull(t, golden, `"collector"`)), message: "must not be null"},
		{name: "null firmware files", document: []byte(replaceOnce(t, golden, `"files": [`, `"files": null,"discarded": [`)), message: "must not be null"},
		{name: "null Bluetooth address", document: []byte(replaceOnce(t, golden, `"address": "10:20:30:40:50:60"`, `"address": null`)), message: "must not be null"},
		{name: "duplicate nested field", document: []byte(replaceOnce(t, golden, `"address": "10:20:30:40:50:60"`, `"address":"10:20:30:40:50:60","address":"10:20:30:40:50:60"`)), message: "duplicate field"},
		{name: "trailing value", document: []byte(golden + ` {}`), message: "multiple JSON values"},
		{name: "byte-order mark", document: append([]byte{0xef, 0xbb, 0xbf}, []byte(golden)...), message: "byte-order mark"},
		{name: "malformed UTF-8", document: append([]byte(golden), 0xff), message: "valid UTF-8"},
		{name: "oversized", document: []byte(strings.Repeat(" ", MaximumDocumentSize+1)), message: "exceeds"},
	}
	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			_, err := Decode(bytes.NewReader(testCase.document))
			if err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("Decode() error = %v, want %q", err, testCase.message)
			}
		})
	}
	if _, err := Decode(nil); err == nil || !strings.Contains(err.Error(), "nil") {
		t.Fatalf("Decode(nil) error = %v, want nil-reader error", err)
	}
}

// TestValidateRejectsEnvelopeAndDeviceViolations exercises every fixed value,
// timestamp, salted binding, and hardware applicability constraint.
func TestValidateRejectsEnvelopeAndDeviceViolations(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name    string
		mutate  func(*Contract)
		message string
	}{
		{name: "schema", mutate: func(contract *Contract) { contract.SchemaVersion = 2 }, message: "schema_version"},
		{name: "kind", mutate: func(contract *Contract) { contract.Kind = "other" }, message: "kind"},
		{name: "privacy", mutate: func(contract *Contract) { contract.PrivacyClassification = "public" }, message: "privacy_classification"},
		{name: "timestamp offset", mutate: func(contract *Contract) { contract.CreatedAt = "2026-08-30T12:34:56+00:00" }, message: "created_at"},
		{name: "timestamp fraction", mutate: func(contract *Contract) { contract.CreatedAt = "2026-08-30T12:34:56.1Z" }, message: "created_at"},
		{name: "collector name", mutate: func(contract *Contract) { contract.Collector.Name = "other.ps1" }, message: "collector name"},
		{name: "collector version", mutate: func(contract *Contract) { contract.Collector.Version = "v1" }, message: "collector version"},
		{name: "platform", mutate: func(contract *Contract) { contract.Device.PlatformID = "other" }, message: "platform_id"},
		{name: "architecture", mutate: func(contract *Contract) { contract.Device.Architecture = "amd64" }, message: "architecture"},
		{name: "short salt", mutate: func(contract *Contract) { contract.Device.BindingSalt = "01" }, message: "binding_salt"},
		{name: "uppercase salt", mutate: func(contract *Contract) { contract.Device.BindingSalt = strings.Repeat("A", 64) }, message: "binding_salt"},
		{name: "zero salt", mutate: func(contract *Contract) { contract.Device.BindingSalt = strings.Repeat("0", 64) }, message: "all zero"},
		{name: "binding digest", mutate: func(contract *Contract) { contract.Device.SMBIOSProductUUIDBindingSHA256 = strings.Repeat("A", 64) }, message: "binding SHA-256"},
		{name: "Wi-Fi identity", mutate: func(contract *Contract) { contract.Device.WiFiPCIID = "17cb:ffff" }, message: "wifi_pci_id"},
	}
	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			contract := decodeGoldenContract(t)
			testCase.mutate(&contract)
			if err := Validate(contract); err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("Validate() error = %v, want %q", err, testCase.message)
			}
		})
	}
}

// TestDeriveDeviceBinding pins the domain-separated algorithm and proves fresh
// salts prevent the same canonical UUID producing a linkable value.
func TestDeriveDeviceBinding(t *testing.T) {
	t.Parallel()

	const uuid = "12345678-1234-5678-9abc-def012345678"
	firstSalt := "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	first, err := DeriveDeviceBinding(firstSalt, uuid)
	if err != nil {
		t.Fatal(err)
	}
	if first != "094fb62588717c3c117b6a5ce3ada6a3d2c247c306239cd0f62f432ea688f600" {
		t.Fatalf("DeriveDeviceBinding() = %s, want pinned vector", first)
	}
	secondSalt := "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"
	second, err := DeriveDeviceBinding(secondSalt, uuid)
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("separate salts produced a linkable device binding")
	}
	for name, inputs := range map[string][2]string{
		"zero salt":      {strings.Repeat("0", 64), uuid},
		"uppercase UUID": {firstSalt, strings.ToUpper(uuid)},
		"braced UUID":    {firstSalt, "{" + uuid + "}"},
	} {
		name, inputs := name, inputs
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := DeriveDeviceBinding(inputs[0], inputs[1]); err == nil {
				t.Fatal("DeriveDeviceBinding() accepted non-canonical input")
			}
		})
	}
}

// TestValidatePlatformFirmwareUnion exercises explicit absence, complete-set,
// immutable mapping, copied-byte, and Windows provenance requirements.
func TestValidatePlatformFirmwareUnion(t *testing.T) {
	t.Parallel()

	t.Run("accepted absence reasons", func(t *testing.T) {
		t.Parallel()
		for _, reason := range []AbsentReason{AbsentReasonNotRequested, AbsentReasonUnavailable} {
			contract := decodeGoldenContract(t)
			contract.PlatformFirmware = PlatformFirmwareSection{Included: false, Reason: testAbsentReason(reason)}
			if err := Validate(contract); err != nil {
				t.Fatalf("Validate(absent %s) error = %v", reason, err)
			}
		}
	})

	testCases := []struct {
		name    string
		mutate  func(*Contract)
		message string
	}{
		{name: "absent reason missing", mutate: func(contract *Contract) { contract.PlatformFirmware = PlatformFirmwareSection{} }, message: "requires reason"},
		{name: "absent files present", mutate: func(contract *Contract) {
			contract.PlatformFirmware = PlatformFirmwareSection{Reason: testAbsentReason(AbsentReasonNotRequested), Files: []FirmwareFileRecord{}}
		}, message: "must not contain files"},
		{name: "absent reason invalid", mutate: func(contract *Contract) {
			contract.PlatformFirmware = PlatformFirmwareSection{Reason: testAbsentReason("other")}
		}, message: "reason is not allowed"},
		{name: "included reason present", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Reason = testAbsentReason(AbsentReasonNotRequested)
		}, message: "must not contain reason"},
		{name: "included files missing", mutate: func(contract *Contract) { contract.PlatformFirmware.Files = nil }, message: "requires files"},
		{name: "partial set", mutate: func(contract *Contract) { contract.PlatformFirmware.Files = contract.PlatformFirmware.Files[:10] }, message: "exactly 11"},
		{name: "reordered set", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0], contract.PlatformFirmware.Files[1] = contract.PlatformFirmware.Files[1], contract.PlatformFirmware.Files[0]
		}, message: "file 0 id"},
		{name: "changed ID", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].ID = "other" }, message: "file 0 id"},
		{name: "changed source", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].SourceName = "other.mbn" }, message: "source_name"},
		{name: "changed payload", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].PayloadPath = "payload/platform-firmware/other.mbn"
		}, message: "payload_path"},
		{name: "changed destination", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].Destination = "lib/firmware/other.mbn" }, message: "destination"},
		{name: "zero size", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].Size = 0 }, message: "size_bytes"},
		{name: "oversized file", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].Size = maximumFirmwareFileSize + 1 }, message: "size_bytes"},
		{name: "oversized total", mutate: func(contract *Contract) {
			for index := range contract.PlatformFirmware.Files {
				contract.PlatformFirmware.Files[index].Size = 100 << 20
			}
		}, message: "exceeds"},
		{name: "uppercase digest", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].SHA256 = strings.Repeat("A", 64) }, message: "SHA-256"},
		{name: "DriverStore traversal", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.DriverStorePath = "Windows/System32/DriverStore/FileRepository/../qcdxkmsuc8380.mbn"
		}, message: "portable relative path"},
		{name: "DriverStore backslash", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.DriverStorePath = `Windows\System32\qcdxkmsuc8380.mbn`
		}, message: "portable relative path"},
		{name: "DriverStore prefix", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.DriverStorePath = "Windows/System32/qcdxkmsuc8380.mbn"
		}, message: "FileRepository"},
		{name: "DriverStore filename", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.DriverStorePath = "Windows/System32/DriverStore/FileRepository/package/other.mbn"
		}, message: "source filename"},
		{name: "published INF", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].WindowsSource.PublishedINF = "driver.inf" }, message: "published_inf"},
		{name: "driver version", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.DriverVersion = "version one"
		}, message: "driver_version"},
		{name: "catalogue digest", mutate: func(contract *Contract) { contract.PlatformFirmware.Files[0].WindowsSource.CatalogueSHA256 = "bad" }, message: "catalogue"},
		{name: "signature claim", mutate: func(contract *Contract) {
			contract.PlatformFirmware.Files[0].WindowsSource.CatalogueSignature = "unknown"
		}, message: "claim a valid"},
	}
	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			contract := decodeGoldenContract(t)
			testCase.mutate(&contract)
			if err := Validate(contract); err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("Validate() error = %v, want %q", err, testCase.message)
			}
		})
	}
}

// TestValidateBluetoothUnion checks absence semantics, provenance completeness,
// address validity, and error redaction.
func TestValidateBluetoothUnion(t *testing.T) {
	t.Parallel()

	t.Run("accepted absence reasons", func(t *testing.T) {
		t.Parallel()
		for _, reason := range []AbsentReason{AbsentReasonNotRequested, AbsentReasonUnavailable} {
			contract := decodeGoldenContract(t)
			contract.BluetoothPublicAddress = BluetoothPublicAddressSection{Included: false, Reason: testAbsentReason(reason)}
			if err := Validate(contract); err != nil {
				t.Fatalf("Validate(absent %s) error = %v", reason, err)
			}
		}
	})

	testCases := []struct {
		name    string
		mutate  func(*Contract)
		message string
	}{
		{name: "absent reason missing", mutate: func(contract *Contract) { contract.BluetoothPublicAddress = BluetoothPublicAddressSection{} }, message: "requires reason"},
		{name: "absent evidence present", mutate: func(contract *Contract) {
			contract.BluetoothPublicAddress.Included = false
			contract.BluetoothPublicAddress.Reason = testAbsentReason(AbsentReasonNotRequested)
		}, message: "must not contain private"},
		{name: "absent reason invalid", mutate: func(contract *Contract) {
			contract.BluetoothPublicAddress = BluetoothPublicAddressSection{Reason: testAbsentReason("other")}
		}, message: "reason is not allowed"},
		{name: "included reason present", mutate: func(contract *Contract) {
			contract.BluetoothPublicAddress.Reason = testAbsentReason(AbsentReasonNotRequested)
		}, message: "must not contain reason"},
		{name: "address missing", mutate: func(contract *Contract) { contract.BluetoothPublicAddress.Address = nil }, message: "requires address"},
		{name: "source missing", mutate: func(contract *Contract) { contract.BluetoothPublicAddress.Source = nil }, message: "requires address"},
		{name: "adapter digest missing", mutate: func(contract *Contract) { contract.BluetoothPublicAddress.AdapterInstanceIDBindingSHA256 = nil }, message: "requires address"},
		{name: "source invalid", mutate: func(contract *Contract) { contract.BluetoothPublicAddress.Source = testBluetoothSource("wifi-derived") }, message: "source"},
		{name: "adapter digest invalid", mutate: func(contract *Contract) {
			contract.BluetoothPublicAddress.AdapterInstanceIDBindingSHA256 = testString("bad")
		}, message: "adapter instance"},
	}
	for _, testCase := range testCases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			contract := decodeGoldenContract(t)
			testCase.mutate(&contract)
			if err := Validate(contract); err == nil || !strings.Contains(err.Error(), testCase.message) {
				t.Fatalf("Validate() error = %v, want %q", err, testCase.message)
			}
		})
	}

	for name, address := range map[string]BluetoothAddress{
		"lowercase":     "10:20:30:40:50:aa",
		"hyphenated":    "10-20-30-40-50-60",
		"zero":          "00:00:00:00:00:00",
		"broadcast":     "FF:FF:FF:FF:FF:FF",
		"kernel marker": "00:00:00:00:5A:AD",
		"repeated":      "AA:AA:AA:AA:AA:AA",
		"illustrative":  "AA:BB:CC:DD:EE:FF",
		"multicast":     "01:20:30:40:50:60",
		"non-hex":       "10:20:30:40:50:GG",
	} {
		name, address := name, address
		t.Run("invalid address "+name, func(t *testing.T) {
			t.Parallel()
			contract := decodeGoldenContract(t)
			contract.BluetoothPublicAddress.Address = &address
			err := Validate(contract)
			if err == nil {
				t.Fatal("Validate() accepted invalid Bluetooth address")
			}
			if strings.Contains(err.Error(), string(address)) {
				t.Fatalf("validation error disclosed Bluetooth address: %v", err)
			}
		})
	}

	contract := decodeGoldenContract(t)
	contract.BluetoothPublicAddress.Source = testBluetoothSource(BluetoothSourceBTHPORT)
	if err := Validate(contract); err != nil {
		t.Fatalf("Validate(BTHPORT source) error = %v", err)
	}
}

// TestValidateRequiresAtLeastOneIncludedSection rejects an otherwise valid
// document containing only absence records.
func TestValidateRequiresAtLeastOneIncludedSection(t *testing.T) {
	t.Parallel()

	contract := decodeGoldenContract(t)
	contract.PlatformFirmware = PlatformFirmwareSection{Reason: testAbsentReason(AbsentReasonNotRequested)}
	contract.BluetoothPublicAddress = BluetoothPublicAddressSection{Reason: testAbsentReason(AbsentReasonUnavailable)}
	if err := Validate(contract); err == nil || !strings.Contains(err.Error(), "must include") {
		t.Fatalf("Validate() error = %v, want at-least-one-section error", err)
	}
}

// TestValidatePortablePathRejectsAlternateSemantics pins path rules independently
// of the exact firmware mappings that normally reject substitutions first.
func TestValidatePortablePathRejectsAlternateSemantics(t *testing.T) {
	t.Parallel()

	for _, value := range []string{
		"", "/absolute", "../escape", "safe/../escape", `Windows\System32`,
		"C:/Windows/file", "double//separator", "./relative", "space in/path",
		"control/line\nfeed",
	} {
		if err := validatePortablePath(value, "test path"); err == nil {
			t.Errorf("validatePortablePath(%q) succeeded, want error", value)
		}
	}
	if err := validatePortablePath("Windows/System32/DriverStore/FileRepository/package/file.mbn", "test path"); err != nil {
		t.Fatalf("validatePortablePath(valid) error = %v", err)
	}
}

// readGoldenDocument returns the immutable v1 fixture bytes.
func readGoldenDocument(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/windows-handoff-v1.golden.json")
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// decodeGoldenContract decodes a fresh deep copy of the v1 fixture for one test.
func decodeGoldenContract(t *testing.T) Contract {
	t.Helper()
	contract, err := Decode(bytes.NewReader(readGoldenDocument(t)))
	if err != nil {
		t.Fatal(err)
	}
	return contract
}

// replaceOnce applies one required textual fixture mutation.
func replaceOnce(t *testing.T, document, old, replacement string) string {
	t.Helper()
	mutated := strings.Replace(document, old, replacement, 1)
	if mutated == document {
		t.Fatalf("fixture mutation did not find %q", old)
	}
	return mutated
}

// replaceObjectWithNull replaces one named top-level object with null while
// retaining all following fields.
func replaceObjectWithNull(t *testing.T, document, field string) string {
	t.Helper()
	start := strings.Index(document, field+": {")
	if start < 0 {
		t.Fatalf("fixture object %s was not found", field)
	}
	objectStart := strings.Index(document[start:], "{") + start
	depth := 0
	for index := objectStart; index < len(document); index++ {
		switch document[index] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return document[:objectStart] + "null" + document[index+1:]
			}
		}
	}
	t.Fatalf("fixture object %s did not close", field)
	return ""
}

// testAbsentReason returns a stable pointer for strict union tests.
func testAbsentReason(value AbsentReason) *AbsentReason {
	return &value
}

// testBluetoothSource returns a stable pointer for provenance tests.
func testBluetoothSource(value BluetoothSource) *BluetoothSource {
	return &value
}

// testString returns a stable string pointer for optional digest tests.
func testString(value string) *string {
	return &value
}
