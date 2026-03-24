package handler

import (
	"testing"

	"github.com/procube-open/scep/utils"
)

func TestNormalizeClientAttributes(t *testing.T) {
	attributes := map[string]interface{}{
		utils.ClientAttributeDeviceID:                 " Device-001 ",
		utils.ClientAttributeAttestationAIKSPKISHA256: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
		utils.ClientAttributeAttestationEKCertSHA256:  "AA-BB-CC-DD-EE-FF-00-11-22-33-44-55-66-77-88-99-AA-BB-CC-DD-EE-FF-00-11-22-33-44-55-66-77-88-99",
	}

	if err := normalizeClientAttributes(attributes); err != nil {
		t.Fatalf("expected normalization to succeed, got %v", err)
	}

	if got := attributes[utils.ClientAttributeDeviceID]; got != "device-001" {
		t.Fatalf("unexpected normalized device_id: %#v", got)
	}
	if got := attributes[utils.ClientAttributeAttestationAIKSPKISHA256]; got != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("unexpected normalized AIK fingerprint: %#v", got)
	}
	if got := attributes[utils.ClientAttributeAttestationEKCertSHA256]; got != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("unexpected normalized EK cert fingerprint: %#v", got)
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
