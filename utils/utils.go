package utils

import (
	"encoding/hex"
	"os"
	"strconv"
	"strings"
)

const (
	ClientAttributeDeviceID                 = "device_id"
	ClientAttributeManagedClientType        = "managed_client_type"
	ClientAttributeAttestationAIKSPKISHA256 = "attestation_aik_spki_sha256"
	ClientAttributeAttestationEKCertSHA256  = "attestation_ek_cert_sha256"
	ClientAttributeAttestationActivationReq = "attestation_activation_required"

	ManagedClientTypeWindowsMSI = "windows-msi"
)

func EnvString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}

func EnvInt(key string, def int) int {
	if env := os.Getenv(key); env != "" {
		num, _ := strconv.Atoi(env)
		return num
	}
	return def
}

func EnvBool(key string) bool {
	if env := os.Getenv(key); env == "true" {
		return true
	}
	return false
}

func NormalizeDeviceID(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}

func NormalizeManagedClientType(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case ManagedClientTypeWindowsMSI:
		return ManagedClientTypeWindowsMSI
	default:
		return ""
	}
}

func NormalizeSHA256Fingerprint(raw string) string {
	normalized := strings.ToLower(strings.TrimSpace(raw))
	normalized = strings.ReplaceAll(normalized, ":", "")
	normalized = strings.ReplaceAll(normalized, "-", "")
	if normalized == "" {
		return ""
	}
	if len(normalized) != 64 {
		return ""
	}
	if _, err := hex.DecodeString(normalized); err != nil {
		return ""
	}
	return normalized
}
