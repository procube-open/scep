//go:build !windows

package main

import "fmt"

func currentDeviceIdentity() (*deviceIdentity, error) {
	return nil, fmt.Errorf("-print-device-id is only supported on Windows")
}
