package scepserver

import (
	"errors"
	"strings"

	"github.com/procube-open/scep/utils"
)

var (
	errRegisteredDeviceIDMissing = errors.New("registered device_id is missing")
	errRequestDeviceIDMismatch   = errors.New("device_id mismatch")
	errEKPublicRequired          = errors.New("ek_public_b64 is required")
	errEKPublicInvalid           = errors.New("ek_public_b64 is not a valid SubjectPublicKeyInfo")
)

func lookupManagedClientType(attributes map[string]interface{}) (string, bool) {
	if attributes == nil {
		return "", false
	}
	raw, ok := attributes[utils.ClientAttributeManagedClientType].(string)
	if !ok {
		return "", false
	}
	managedClientType := utils.NormalizeManagedClientType(raw)
	if managedClientType == "" {
		return "", false
	}
	return managedClientType, true
}

func isWindowsManagedClient(attributes map[string]interface{}) bool {
	managedClientType, ok := lookupManagedClientType(attributes)
	return ok && managedClientType == utils.ManagedClientTypeWindowsMSI
}

func validateClientDeviceIDBinding(attributes map[string]interface{}, requestDeviceID, ekPublicB64 string) (string, error) {
	registeredDeviceID, ok := lookupDeviceID(attributes)
	if !ok {
		return "", errRegisteredDeviceIDMissing
	}

	requestDeviceID = utils.NormalizeDeviceID(requestDeviceID)
	if requestDeviceID == "" {
		return "", errRequestDeviceIDMismatch
	}

	if !isWindowsManagedClient(attributes) {
		if registeredDeviceID != requestDeviceID {
			return "", errRequestDeviceIDMismatch
		}
		return registeredDeviceID, nil
	}

	ekPublicB64 = strings.TrimSpace(ekPublicB64)
	if ekPublicB64 == "" {
		return "", errEKPublicRequired
	}

	canonicalDeviceID, err := utils.CanonicalDeviceIDFromBase64URLPKIXPublicKey(ekPublicB64)
	if err != nil {
		return "", errEKPublicInvalid
	}

	if registeredDeviceID != canonicalDeviceID || requestDeviceID != canonicalDeviceID {
		return "", errRequestDeviceIDMismatch
	}

	return registeredDeviceID, nil
}
