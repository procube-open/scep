//go:build !windows

package main

func shouldShowDeviceIdentityReport(defaultProbeMode bool, jsonOutput bool) bool {
	return false
}

func shouldShowDeviceIdentityInteractive(defaultProbeMode bool, jsonOutput bool, standaloneConsole bool) bool {
	return defaultProbeMode && !jsonOutput && standaloneConsole
}

func presentDeviceIdentityReport(output string) error {
	return nil
}

func presentDeviceIdentityError(err error) error {
	return err
}
