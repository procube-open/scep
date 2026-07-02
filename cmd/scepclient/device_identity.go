package main

import (
	"encoding/json"
	"fmt"
)

type deviceIdentity struct {
	ExpectedDeviceID        string `json:"expected_device_id,omitempty"`
	DeviceID                string `json:"device_id"`
	EKPublicB64             string `json:"ek_public_b64"`
	EKCertB64               string `json:"ek_cert_b64,omitempty"`
	AttestationEKCertSHA256 string `json:"attestation_ek_cert_sha256,omitempty"`
}

func printCurrentDeviceIdentity(jsonOutput bool, openReport bool) (bool, error) {
	identity, err := currentDeviceIdentity()
	if err != nil {
		if openReport {
			if reportErr := presentDeviceIdentityError(err); reportErr != nil {
				return true, reportErr
			}
			return true, err
		}
		return false, err
	}
	output, err := formatDeviceIdentityOutput(identity, jsonOutput)
	if err != nil {
		if openReport {
			if reportErr := presentDeviceIdentityError(err); reportErr != nil {
				return true, reportErr
			}
			return true, err
		}
		return false, err
	}
	if openReport {
		return true, presentDeviceIdentityReport(output)
	}
	fmt.Print(output)
	return false, nil
}

func formatDeviceIdentityOutput(identity *deviceIdentity, jsonOutput bool) (string, error) {
	if identity == nil {
		return "", fmt.Errorf("device identity is unavailable")
	}
	if jsonOutput {
		encoded, err := json.Marshal(identity)
		if err != nil {
			return "", err
		}
		return string(encoded) + "\n", nil
	}

	output := ""
	if identity.ExpectedDeviceID != "" {
		output += fmt.Sprintf("expected_device_id: %s\n", identity.ExpectedDeviceID)
	}
	output += fmt.Sprintf("device_id: %s\n", identity.DeviceID)
	output += fmt.Sprintf("ek_public_b64: %s\n", identity.EKPublicB64)
	if identity.EKCertB64 != "" {
		output += fmt.Sprintf("ek_cert_b64: %s\n", identity.EKCertB64)
	}
	if identity.AttestationEKCertSHA256 != "" {
		output += fmt.Sprintf("attestation_ek_cert_sha256: %s\n", identity.AttestationEKCertSHA256)
	}
	return output, nil
}
