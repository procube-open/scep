package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestDecodeAttestationPayloadNormalizesFields(t *testing.T) {
	payload := map[string]any{
		"device_id": " Device-001 ",
		"key": map[string]any{
			"algorithm":           "rsa-2048",
			"provider":            "Microsoft Platform Crypto Provider",
			"public_key_spki_b64": "YWJj",
		},
		"attestation": map[string]any{
			"format":               "tpm2-windows-v1-placeholder-initial",
			"nonce":                " bm9uY2U ",
			"activation_id":        " activation-id ",
			"activation_proof_b64": " activation-proof ",
		},
		"meta": map[string]any{
			"hostname":     " host ",
			"os_version":   " windows ",
			"generated_at": " now ",
		},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	claims, err := decodeAttestationPayload(base64.RawURLEncoding.EncodeToString(raw))
	if err != nil {
		t.Fatalf("decodeAttestationPayload returned error: %v", err)
	}

	if claims.DeviceID != "device-001" {
		t.Fatalf("unexpected normalized device_id: %q", claims.DeviceID)
	}
	if claims.Attestation.Format != "tpm2-windows-v1-placeholder-initial" {
		t.Fatalf("unexpected format: %q", claims.Attestation.Format)
	}
	if claims.Attestation.Nonce != "bm9uY2U" {
		t.Fatalf("unexpected nonce: %q", claims.Attestation.Nonce)
	}
	if claims.Attestation.ActivationID != "activation-id" {
		t.Fatalf("unexpected activation_id: %q", claims.Attestation.ActivationID)
	}
	if claims.Attestation.ActivationProofB64 != "activation-proof" {
		t.Fatalf("unexpected activation_proof_b64: %q", claims.Attestation.ActivationProofB64)
	}
}

func TestEncodeCanonicalAttestationPayloadIncludesQuoteFields(t *testing.T) {
	encoded, err := encodeAttestationPayload(buildCanonicalAttestationClaims(
		"Device-001",
		attestationKey{
			Algorithm:        defaultWindowsKeyAlgorithm,
			Provider:         "Microsoft Platform Crypto Provider",
			PublicKeySPKIB64: "cHVibGlj",
		},
		"bm9uY2U",
		"YWlr",
		"YWlrLXRwbQ",
		"activation-id",
		"proof",
		"cXVvdGU",
		"c2ln",
		"ZWstcHVibGlj",
		"ZWstY2VydA",
		"https://example.invalid/ek",
	))
	if err != nil {
		t.Fatalf("encodeAttestationPayload returned error: %v", err)
	}

	raw, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode encoded attestation: %v", err)
	}

	value := map[string]any{}
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatalf("json.Unmarshal returned error: %v", err)
	}

	attestation, ok := value["attestation"].(map[string]any)
	if !ok {
		t.Fatalf("missing attestation object: %#v", value["attestation"])
	}

	if value["device_id"] != "device-001" {
		t.Fatalf("unexpected device_id: %#v", value["device_id"])
	}
	if attestation["format"] != canonicalWindowsTPMAttestationFormat {
		t.Fatalf("unexpected format: %#v", attestation["format"])
	}
	if attestation["aik_public_b64"] != "YWlr" {
		t.Fatalf("unexpected aik_public_b64: %#v", attestation["aik_public_b64"])
	}
	if attestation["aik_tpm_public_b64"] != "YWlrLXRwbQ" {
		t.Fatalf("unexpected aik_tpm_public_b64: %#v", attestation["aik_tpm_public_b64"])
	}
	if attestation["activation_id"] != "activation-id" {
		t.Fatalf("unexpected activation_id: %#v", attestation["activation_id"])
	}
	if attestation["activation_proof_b64"] != "proof" {
		t.Fatalf("unexpected activation_proof_b64: %#v", attestation["activation_proof_b64"])
	}
	if attestation["quote_b64"] != "cXVvdGU" {
		t.Fatalf("unexpected quote_b64: %#v", attestation["quote_b64"])
	}
	if attestation["quote_signature_b64"] != "c2ln" {
		t.Fatalf("unexpected quote_signature_b64: %#v", attestation["quote_signature_b64"])
	}
	if attestation["ek_cert_b64"] != "ZWstY2VydA" {
		t.Fatalf("unexpected ek_cert_b64: %#v", attestation["ek_cert_b64"])
	}
	if attestation["ek_public_b64"] != "ZWstcHVibGlj" {
		t.Fatalf("unexpected ek_public_b64: %#v", attestation["ek_public_b64"])
	}
	if attestation["ek_certificate_url"] != "https://example.invalid/ek" {
		t.Fatalf("unexpected ek_certificate_url: %#v", attestation["ek_certificate_url"])
	}

	meta, ok := value["meta"].(map[string]any)
	if !ok || !strings.HasPrefix(meta["generated_at"].(string), "unix:") {
		t.Fatalf("unexpected generated_at: %#v", value["meta"])
	}
}
