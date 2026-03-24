//go:build windows

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"unsafe"

	"github.com/google/go-attestation/attest"
	legacytpm2 "github.com/google/go-tpm/legacy/tpm2"
	"golang.org/x/sys/windows"
)

const (
	windowsPCPProviderName = "Microsoft Platform Crypto Provider"
	nCryptNotFound         = 0x80090011
	nCryptBadKeyset        = 0x80090016
)

func maybeUpgradeAttestation(attestation, keyProvider, keyName, publicKeySPKI string) (string, error) {
	if strings.TrimSpace(attestation) == "" || strings.TrimSpace(keyProvider) == "" || strings.TrimSpace(keyName) == "" || strings.TrimSpace(publicKeySPKI) == "" {
		return attestation, nil
	}
	if err := validatePublicKeySPKI(publicKeySPKI); err != nil {
		return "", err
	}

	claims, err := decodeAttestationPayload(attestation)
	if err != nil {
		return "", err
	}

	switch {
	case claims.Attestation.Format == canonicalWindowsTPMAttestationFormat &&
		claims.Attestation.AIKPublicB64 != "" &&
		claims.Attestation.QuoteB64 != "" &&
		claims.Attestation.QuoteSignatureB64 != "":
		return attestation, nil
	case strings.HasPrefix(claims.Attestation.Format, placeholderWindowsTPMAttestationFmt),
		claims.Attestation.Format == canonicalWindowsTPMAttestationFormat:
		return buildWindowsCanonicalAttestation(claims, keyProvider, keyName, publicKeySPKI)
	default:
		return attestation, nil
	}
}

func buildWindowsCanonicalAttestation(claims *attestationClaims, keyProvider, keyName, publicKeySPKI string) (string, error) {
	if claims == nil {
		return "", fmt.Errorf("attestation payload is missing")
	}
	if claims.DeviceID == "" {
		return "", fmt.Errorf("attestation payload is missing device_id")
	}
	if claims.Attestation.Nonce == "" {
		return "", fmt.Errorf("attestation payload is missing nonce")
	}

	publicKeySPKI = strings.TrimSpace(publicKeySPKI)
	if embedded := strings.TrimSpace(claims.Key.PublicKeySPKIB64); embedded != "" && embedded != publicKeySPKI {
		return "", fmt.Errorf("embedded attested public key did not match helper input")
	}

	aikDER, quoteWire, signatureWire, err := buildWindowsTPMQuote(keyName, publicKeySPKI, claims.Attestation.Nonce)
	if err != nil {
		return "", err
	}

	keyAlgorithm := claims.Key.Algorithm
	if keyAlgorithm == "" {
		keyAlgorithm = defaultWindowsKeyAlgorithm
	}
	keyProvider = strings.TrimSpace(keyProvider)
	if claims.Key.Provider != "" {
		keyProvider = claims.Key.Provider
	}

	encoded, err := encodeAttestationPayload(buildCanonicalAttestationClaims(
		claims.DeviceID,
		attestationKey{
			Algorithm:        keyAlgorithm,
			Provider:         keyProvider,
			PublicKeySPKIB64: publicKeySPKI,
		},
		claims.Attestation.Nonce,
		base64.RawURLEncoding.EncodeToString(aikDER),
		base64.RawURLEncoding.EncodeToString(quoteWire),
		base64.RawURLEncoding.EncodeToString(signatureWire),
	))
	if err != nil {
		return "", err
	}

	return encoded, nil
}

func buildWindowsTPMQuote(keyName, publicKeySPKI, nonceB64 string) (aikDER, quoteWire, signatureWire []byte, err error) {
	publicKeyDER, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(publicKeySPKI))
	if err != nil {
		return nil, nil, nil, fmt.Errorf("decode public key spki: %w", err)
	}
	if _, err := x509.ParsePKIXPublicKey(publicKeyDER); err != nil {
		return nil, nil, nil, fmt.Errorf("parse public key spki: %w", err)
	}

	nonceBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(nonceB64))
	if err != nil {
		return nil, nil, nil, fmt.Errorf("decode attestation nonce: %w", err)
	}
	if len(nonceBytes) == 0 {
		return nil, nil, nil, fmt.Errorf("attestation nonce was empty")
	}

	keyDigest := sha256.Sum256(publicKeyDER)
	extraData := append(keyDigest[:], nonceBytes...)

	akName, err := newWindowsAttestationKeyName(keyName)
	if err != nil {
		return nil, nil, nil, err
	}

	tpm, err := attest.OpenTPM(nil)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("open Windows TPM: %w", err)
	}

	var ak *attest.AK
	defer func() {
		cleanupErr := cleanupWindowsAttestationResources(tpm, ak, akName)
		if cleanupErr == nil {
			return
		}
		if err == nil {
			err = cleanupErr
			return
		}
		err = errors.Join(err, cleanupErr)
	}()

	ak, err = tpm.NewAK(&attest.AKConfig{
		Name:      akName,
		Algorithm: attest.RSA,
	})
	if err != nil {
		return nil, nil, nil, fmt.Errorf("create Windows attestation key: %w", err)
	}

	params := ak.AttestationParameters()
	aikDER, err = encodeLegacyTPMPublicToSPKI(params.Public)
	if err != nil {
		return nil, nil, nil, err
	}

	quote, err := quoteWithWindowsAK(ak, tpm, extraData)
	if err != nil {
		compactBinding := sha256.Sum256(extraData)
		var compactErr error
		quote, compactErr = quoteWithWindowsAK(ak, tpm, compactBinding[:])
		if compactErr != nil {
			return nil, nil, nil, errors.Join(err, fmt.Errorf("compact quote binding failed: %w", compactErr))
		}
	}

	return aikDER, quote.Quote, quote.Signature, nil
}

func quoteWithWindowsAK(ak *attest.AK, tpm *attest.TPM, extraData []byte) (*attest.Quote, error) {
	strategies := []struct {
		name string
		alg  attest.HashAlg
		pcrs []int
	}{
		{name: "sha256-pcr7", alg: attest.HashSHA256, pcrs: []int{7}},
		{name: "sha1-pcr7", alg: attest.HashSHA1, pcrs: []int{7}},
		{name: "sha256-empty", alg: attest.HashSHA256, pcrs: nil},
	}

	var attemptErrors []string
	for _, strategy := range strategies {
		quote, err := ak.QuotePCRs(tpm, extraData, strategy.alg, strategy.pcrs)
		if err == nil {
			return quote, nil
		}
		attemptErrors = append(attemptErrors, fmt.Sprintf("%s: %v", strategy.name, err))
	}

	if len(attemptErrors) == 0 {
		return nil, fmt.Errorf("TPM2_Quote failed without a detailed error")
	}
	return nil, fmt.Errorf("TPM2_Quote failed for all AK strategies: %s", strings.Join(attemptErrors, "; "))
}

func encodeLegacyTPMPublicToSPKI(tpmPublic []byte) ([]byte, error) {
	public, err := legacytpm2.DecodePublic(tpmPublic)
	if err != nil {
		return nil, fmt.Errorf("decode AIK public area: %w", err)
	}

	cryptoPublic, err := public.Key()
	if err != nil {
		return nil, fmt.Errorf("convert AIK public key: %w", err)
	}

	spki, err := x509.MarshalPKIXPublicKey(cryptoPublic)
	if err != nil {
		return nil, fmt.Errorf("marshal AIK public key: %w", err)
	}
	return spki, nil
}

func newWindowsAttestationKeyName(keyName string) (string, error) {
	randomSuffix := make([]byte, 6)
	if _, err := rand.Read(randomSuffix); err != nil {
		return "", fmt.Errorf("generate Windows attestation key name: %w", err)
	}

	keyHash := sha256.Sum256([]byte(strings.TrimSpace(keyName)))
	return fmt.Sprintf("scep-attest-%x-%x", keyHash[:4], randomSuffix), nil
}

func cleanupWindowsAttestationResources(tpm *attest.TPM, ak *attest.AK, akName string) error {
	var err error

	if ak != nil && tpm != nil {
		if closeErr := ak.Close(tpm); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("close Windows attestation key %q: %w", akName, closeErr))
		}
	}
	if tpm != nil {
		if closeErr := tpm.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("close Windows TPM: %w", closeErr))
		}
	}
	if deleteErr := deleteWindowsAttestationKeyByName(akName); deleteErr != nil {
		err = errors.Join(err, deleteErr)
	}

	return err
}

func deleteWindowsAttestationKeyByName(name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}

	provider, err := openWindowsPCPProvider()
	if err != nil {
		return err
	}
	defer freeNCryptObject(provider)

	keyHandle, found, err := openWindowsPCPKey(provider, name)
	if err != nil {
		return err
	}
	if !found {
		return nil
	}

	result, _, callErr := procNCryptDeleteKey.Call(keyHandle, 0)
	if result != 0 {
		_ = freeNCryptObject(keyHandle)
		return fmt.Errorf("delete Windows attestation key %q: NCryptDeleteKey returned 0x%X: %v", name, uint32(result), callErr)
	}
	return nil
}

func openWindowsPCPProvider() (uintptr, error) {
	providerName, err := windows.UTF16PtrFromString(windowsPCPProviderName)
	if err != nil {
		return 0, fmt.Errorf("encode PCP provider name: %w", err)
	}

	var provider uintptr
	result, _, callErr := procNCryptOpenStorageProvider.Call(
		uintptr(unsafe.Pointer(&provider)),
		uintptr(unsafe.Pointer(providerName)),
		0,
	)
	if result != 0 {
		return 0, fmt.Errorf("open PCP provider: NCryptOpenStorageProvider returned 0x%X: %v", uint32(result), callErr)
	}
	return provider, nil
}

func openWindowsPCPKey(provider uintptr, name string) (uintptr, bool, error) {
	keyName, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return 0, false, fmt.Errorf("encode attestation key name: %w", err)
	}

	var keyHandle uintptr
	result, _, callErr := procNCryptOpenKey.Call(
		provider,
		uintptr(unsafe.Pointer(&keyHandle)),
		uintptr(unsafe.Pointer(keyName)),
		0,
		ncryptMachineKeyFlag,
	)
	if result != 0 {
		switch uint32(result) {
		case nCryptNotFound, nCryptBadKeyset:
			return 0, false, nil
		}
		return 0, false, fmt.Errorf("open Windows attestation key %q: NCryptOpenKey returned 0x%X: %v", name, uint32(result), callErr)
	}
	return keyHandle, true, nil
}

func freeNCryptObject(handle uintptr) error {
	if handle == 0 {
		return nil
	}

	result, _, callErr := procNCryptFreeObject.Call(handle)
	if result != 0 {
		return fmt.Errorf("free NCrypt handle 0x%X: NCryptFreeObject returned 0x%X: %v", handle, uint32(result), callErr)
	}
	return nil
}
