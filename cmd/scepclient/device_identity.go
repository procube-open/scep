package main

import (
	"encoding/json"
	"fmt"
)

type deviceIdentity struct {
	ExpectedDeviceID string `json:"expected_device_id,omitempty"`
	DeviceID         string `json:"device_id"`
	EKPublicB64      string `json:"ek_public_b64"`
}

func printCurrentDeviceIdentity(jsonOutput bool) error {
	identity, err := currentDeviceIdentity()
	if err != nil {
		return err
	}
	output, err := formatDeviceIdentityOutput(identity, jsonOutput)
	if err != nil {
		return err
	}
	fmt.Print(output)
	return nil
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
	return output, nil
}
