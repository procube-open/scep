//go:build !windows

package main

func maybeUpgradeAttestation(attestation, _ string, _ string, _ string, _ string, _ string) (string, error) {
	return attestation, nil
}
