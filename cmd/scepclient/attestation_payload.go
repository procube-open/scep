package main

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"
)

const (
	canonicalWindowsTPMAttestationFormat = "tpm2-windows-v1"
	placeholderWindowsTPMAttestationFmt  = "tpm2-windows-v1-placeholder-"
	defaultWindowsKeyAlgorithm           = "rsa-2048"
)

type attestationClaims struct {
	DeviceID    string            `json:"device_id"`
	Key         attestationKey    `json:"key"`
	Attestation attestationBundle `json:"attestation"`
	Meta        attestationMeta   `json:"meta"`
}

type attestationKey struct {
	Algorithm        string `json:"algorithm"`
	Provider         string `json:"provider"`
	PublicKeySPKIB64 string `json:"public_key_spki_b64,omitempty"`
}

type attestationBundle struct {
	Format             string `json:"format"`
	Nonce              string `json:"nonce"`
	AIKPublicB64       string `json:"aik_public_b64,omitempty"`
	AIKTPMPublicB64    string `json:"aik_tpm_public_b64,omitempty"`
	ActivationID       string `json:"activation_id,omitempty"`
	ActivationProofB64 string `json:"activation_proof_b64,omitempty"`
	QuoteB64           string `json:"quote_b64,omitempty"`
	QuoteSignatureB64  string `json:"quote_signature_b64,omitempty"`
	EKPublicB64        string `json:"ek_public_b64,omitempty"`
	EKCertB64          string `json:"ek_cert_b64,omitempty"`
	EKCertificateURL   string `json:"ek_certificate_url,omitempty"`
}

type attestationMeta struct {
	Hostname    string `json:"hostname"`
	OSVersion   string `json:"os_version"`
	GeneratedAt string `json:"generated_at"`
}

func decodeAttestationPayload(encoded string) (*attestationClaims, error) {
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, fmt.Errorf("decode attestation payload: %w", err)
	}

	var claims attestationClaims
	if err := json.Unmarshal(raw, &claims); err != nil {
		return nil, fmt.Errorf("decode attestation json: %w", err)
	}

	claims.DeviceID = normalizeDeviceID(claims.DeviceID)
	claims.Key.Algorithm = strings.TrimSpace(claims.Key.Algorithm)
	claims.Key.Provider = strings.TrimSpace(claims.Key.Provider)
	claims.Key.PublicKeySPKIB64 = strings.TrimSpace(claims.Key.PublicKeySPKIB64)
	claims.Attestation.Format = strings.TrimSpace(claims.Attestation.Format)
	claims.Attestation.Nonce = strings.TrimSpace(claims.Attestation.Nonce)
	claims.Attestation.AIKPublicB64 = strings.TrimSpace(claims.Attestation.AIKPublicB64)
	claims.Attestation.AIKTPMPublicB64 = strings.TrimSpace(claims.Attestation.AIKTPMPublicB64)
	claims.Attestation.ActivationID = strings.TrimSpace(claims.Attestation.ActivationID)
	claims.Attestation.ActivationProofB64 = strings.TrimSpace(claims.Attestation.ActivationProofB64)
	claims.Attestation.QuoteB64 = strings.TrimSpace(claims.Attestation.QuoteB64)
	claims.Attestation.QuoteSignatureB64 = strings.TrimSpace(claims.Attestation.QuoteSignatureB64)
	claims.Attestation.EKPublicB64 = strings.TrimSpace(claims.Attestation.EKPublicB64)
	claims.Attestation.EKCertB64 = strings.TrimSpace(claims.Attestation.EKCertB64)
	claims.Attestation.EKCertificateURL = strings.TrimSpace(claims.Attestation.EKCertificateURL)
	claims.Meta.Hostname = strings.TrimSpace(claims.Meta.Hostname)
	claims.Meta.OSVersion = strings.TrimSpace(claims.Meta.OSVersion)
	claims.Meta.GeneratedAt = strings.TrimSpace(claims.Meta.GeneratedAt)

	return &claims, nil
}

func encodeAttestationPayload(claims *attestationClaims) (string, error) {
	if claims == nil {
		return "", fmt.Errorf("attestation claims are missing")
	}

	raw, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("encode attestation json: %w", err)
	}

	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func decodeBase64URL(payload string) ([]byte, error) {
	if decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(payload)); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(strings.TrimSpace(payload))
}

func validatePublicKeySPKI(publicKeySPKI string) error {
	der, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(publicKeySPKI))
	if err != nil {
		return fmt.Errorf("decode public key spki: %w", err)
	}
	if _, err := x509.ParsePKIXPublicKey(der); err != nil {
		return fmt.Errorf("parse public key spki: %w", err)
	}
	return nil
}

func buildCanonicalAttestationClaims(
	deviceID string,
	key attestationKey,
	nonce string,
	aikPublicB64 string,
	aikTPMPublicB64 string,
	activationID string,
	activationProofB64 string,
	quoteB64 string,
	quoteSignatureB64 string,
	ekPublicB64 string,
	ekCertB64 string,
	ekCertificateURL string,
) *attestationClaims {
	return &attestationClaims{
		DeviceID: normalizeDeviceID(deviceID),
		Key:      key,
		Attestation: attestationBundle{
			Format:             canonicalWindowsTPMAttestationFormat,
			Nonce:              strings.TrimSpace(nonce),
			AIKPublicB64:       strings.TrimSpace(aikPublicB64),
			AIKTPMPublicB64:    strings.TrimSpace(aikTPMPublicB64),
			ActivationID:       strings.TrimSpace(activationID),
			ActivationProofB64: strings.TrimSpace(activationProofB64),
			QuoteB64:           strings.TrimSpace(quoteB64),
			QuoteSignatureB64:  strings.TrimSpace(quoteSignatureB64),
			EKPublicB64:        strings.TrimSpace(ekPublicB64),
			EKCertB64:          strings.TrimSpace(ekCertB64),
			EKCertificateURL:   strings.TrimSpace(ekCertificateURL),
		},
		Meta: attestationMeta{
			Hostname:    currentHostname(),
			OSVersion:   runtime.GOOS,
			GeneratedAt: fmt.Sprintf("unix:%d", time.Now().Unix()),
		},
	}
}

func currentHostname() string {
	hostname, err := os.Hostname()
	if err == nil {
		hostname = strings.TrimSpace(hostname)
		if hostname != "" {
			return hostname
		}
	}
	return "unknown-host"
}

func normalizeDeviceID(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
