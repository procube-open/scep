package handler

import (
	"testing"

	"github.com/procube-open/scep/utils"
)

func TestNormalizeClientAttributes(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeManagedClientType:        " Windows-MSI ",
		utils.ClientAttributeDeviceID:                 "AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899",
		utils.ClientAttributeAttestationAIKSPKISHA256: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
		utils.ClientAttributeAttestationEKCertSHA256:  "AA-BB-CC-DD-EE-FF-00-11-22-33-44-55-66-77-88-99-AA-BB-CC-DD-EE-FF-00-11-22-33-44-55-66-77-88-99",
	}

	if err := normalizeClientAttributes(attributes); err != nil {
		t.Fatalf("expected normalization to succeed, got %v", err)
	}

	if got := attributes[utils.ClientAttributeDeviceID]; got != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("unexpected normalized device_id: %#v", got)
	}
	if got := attributes[utils.ClientAttributeAttestationAIKSPKISHA256]; got != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("unexpected normalized AIK fingerprint: %#v", got)
	}
	if got := attributes[utils.ClientAttributeAttestationEKCertSHA256]; got != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("unexpected normalized EK cert fingerprint: %#v", got)
	}
	if got := attributes[utils.ClientAttributeManagedClientType]; got != utils.ManagedClientTypeWindowsMSI {
		t.Fatalf("unexpected normalized managed client type: %#v", got)
	}
}

func TestNormalizeClientAttributesRejectsInvalidFingerprint(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeAttestationAIKSPKISHA256: "not-a-fingerprint",
	}

	err := normalizeClientAttributes(attributes)
	if err == nil {
		t.Fatal("expected invalid AIK fingerprint to fail")
	}
	if got := err.Error(); got != "attestation_aik_spki_sha256 must be a 64-character SHA-256 fingerprint" {
		t.Fatalf("unexpected error: %v", got)
	}
}

func TestNormalizeClientAttributesRejectsInvalidManagedClientType(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeManagedClientType: "definitely-not-supported",
	}

	err := normalizeClientAttributes(attributes)
	if err == nil {
		t.Fatal("expected invalid managed client type to fail")
	}
	if got := err.Error(); got != `managed_client_type must be "windows-msi"` {
		t.Fatalf("unexpected error: %v", got)
	}
}

func TestNormalizeClientAttributesRejectsDeprecatedActivationAttribute(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeAttestationActivationReq: true,
	}

	err := normalizeClientAttributes(attributes)
	if err == nil {
		t.Fatal("expected deprecated activation attribute to fail")
	}
	if got := err.Error(); got != "attestation_activation_required has been replaced by managed_client_type" {
		t.Fatalf("unexpected error: %v", got)
	}
}

func TestNormalizeClientAttributesRequiresDeviceIDForWindowsMSI(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
	}

	err := normalizeClientAttributes(attributes)
	if err == nil {
		t.Fatal("expected windows managed client without device_id to fail")
	}
	if got := err.Error(); got != "device_id is required when managed_client_type=windows-msi" {
		t.Fatalf("unexpected error: %v", got)
	}
}

func TestNormalizeClientAttributesRejectsNonCanonicalWindowsMSIDeviceID(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
		utils.ClientAttributeDeviceID:          "aa:bb:cc",
	}

	err := normalizeClientAttributes(attributes)
	if err == nil {
		t.Fatal("expected non-canonical device_id to fail")
	}
	if got := err.Error(); got != "device_id must be a lowercase 64-character SHA-256 fingerprint when managed_client_type=windows-msi" {
		t.Fatalf("unexpected error: %v", got)
	}
}
