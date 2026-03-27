//go:build windows

package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unsafe"

	"github.com/google/go-attestation/attest"
	legacytpm2 "github.com/google/go-tpm/legacy/tpm2"
	"golang.org/x/sys/windows"

	"github.com/procube-open/scep/utils"
)

const (
	windowsPCPProviderName = "Microsoft Platform Crypto Provider"
	nCryptNotFound         = 0x80090011
	nCryptBadKeyset        = 0x80090016
)

type windowsTPMQuoteMaterial struct {
	DeviceID                  string
	AIKDER                    []byte
	AIKTPMPublic              []byte
	AKUseTCSDActivationFormat bool
	AKCreateData              []byte
	AKCreateAttestation       []byte
	AKCreateSignature         []byte
	ActivationID              string
	ActivationProof           []byte
	QuoteWire                 []byte
	SignatureWire             []byte
	EKPublicSPKIDER           []byte
	EKCertDER                 []byte
	EKCertificateURL          string
}

func maybeUpgradeAttestation(attestation, keyProvider, keyName, publicKeySPKI, serverURL, clientUID string) (string, error) {
	if strings.TrimSpace(attestation) == "" || strings.TrimSpace(keyProvider) == "" || strings.TrimSpace(keyName) == "" {
		return attestation, nil
	}
	activationRequested := strings.TrimSpace(serverURL) != "" && strings.TrimSpace(clientUID) != ""
	publicKeySPKI = strings.TrimSpace(publicKeySPKI)
	if publicKeySPKI == "" {
		key, err := openWindowsNCryptKey(keyProvider, keyName, "")
		if err != nil {
			return "", err
		}
		defer key.Close()
		publicKeySPKI = key.publicKeySPKI
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
		claims.Attestation.AIKTPMPublicB64 != "" &&
		claims.Attestation.QuoteB64 != "" &&
		claims.Attestation.QuoteSignatureB64 != "" &&
		claims.Attestation.EKPublicB64 != "" &&
		(!activationRequested || (claims.Attestation.ActivationID != "" && claims.Attestation.ActivationProofB64 != "")):
		if err := validateCanonicalWindowsDeviceID(claims); err != nil {
			return "", err
		}
		return attestation, nil
	case strings.HasPrefix(claims.Attestation.Format, placeholderWindowsTPMAttestationFmt),
		claims.Attestation.Format == canonicalWindowsTPMAttestationFormat:
		return buildWindowsCanonicalAttestation(claims, keyProvider, keyName, publicKeySPKI, serverURL, clientUID)
	default:
		return attestation, nil
	}
}

func buildWindowsCanonicalAttestation(claims *attestationClaims, keyProvider, keyName, publicKeySPKI, serverURL, clientUID string) (string, error) {
	if claims == nil {
		return "", fmt.Errorf("attestation payload is missing")
	}
	if claims.Attestation.Nonce == "" {
		return "", fmt.Errorf("attestation payload is missing nonce")
	}

	publicKeySPKI = strings.TrimSpace(publicKeySPKI)
	if embedded := strings.TrimSpace(claims.Key.PublicKeySPKIB64); embedded != "" && embedded != publicKeySPKI {
		return "", fmt.Errorf("embedded attested public key did not match helper input")
	}

	material, err := buildWindowsTPMQuote(
		keyName,
		publicKeySPKI,
		claims.Attestation.Nonce,
		serverURL,
		clientUID,
	)
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
		material.DeviceID,
		attestationKey{
			Algorithm:        keyAlgorithm,
			Provider:         keyProvider,
			PublicKeySPKIB64: publicKeySPKI,
		},
		claims.Attestation.Nonce,
		base64.RawURLEncoding.EncodeToString(material.AIKDER),
		base64.RawURLEncoding.EncodeToString(material.AIKTPMPublic),
		material.ActivationID,
		base64.RawURLEncoding.EncodeToString(material.ActivationProof),
		base64.RawURLEncoding.EncodeToString(material.QuoteWire),
		base64.RawURLEncoding.EncodeToString(material.SignatureWire),
		base64.RawURLEncoding.EncodeToString(material.EKPublicSPKIDER),
		base64.RawURLEncoding.EncodeToString(material.EKCertDER),
		material.EKCertificateURL,
	))
	if err != nil {
		return "", err
	}

	return encoded, nil
}

func buildWindowsTPMQuote(keyName, publicKeySPKI, nonceB64, serverURL, clientUID string) (_ *windowsTPMQuoteMaterial, err error) {
	publicKeyDER, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(publicKeySPKI))
	if err != nil {
		return nil, fmt.Errorf("decode public key spki: %w", err)
	}
	if _, err := x509.ParsePKIXPublicKey(publicKeyDER); err != nil {
		return nil, fmt.Errorf("parse public key spki: %w", err)
	}

	nonceBytes, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(nonceB64))
	if err != nil {
		return nil, fmt.Errorf("decode attestation nonce: %w", err)
	}
	if len(nonceBytes) == 0 {
		return nil, fmt.Errorf("attestation nonce was empty")
	}

	keyDigest := sha256.Sum256(publicKeyDER)
	extraData := append(keyDigest[:], nonceBytes...)

	akName, err := newWindowsAttestationKeyName(keyName)
	if err != nil {
		return nil, err
	}

	tpm, err := attest.OpenTPM(nil)
	if err != nil {
		return nil, fmt.Errorf("open Windows TPM: %w", err)
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
		return nil, fmt.Errorf("create Windows attestation key: %w", err)
	}

	params := ak.AttestationParameters()
	aikDER, err := encodeLegacyTPMPublicToSPKI(params.Public)
	if err != nil {
		return nil, err
	}

	ekPublicSPKIDER, ekCertDER, ekCertificateURL, err := readWindowsEndorsementKey(tpm)
	if err != nil {
		ekPublicSPKIDER = nil
		ekCertDER = nil
		ekCertificateURL = ""
	}
	if len(ekPublicSPKIDER) == 0 {
		return nil, fmt.Errorf("Windows endorsement key is unavailable")
	}
	deviceID, err := utils.CanonicalDeviceIDFromPKIXPublicKeyDER(ekPublicSPKIDER)
	if err != nil {
		return nil, fmt.Errorf("derive canonical device_id from Windows EK public key: %w", err)
	}

	quote, err := quoteWithWindowsAK(ak, tpm, extraData)
	if err != nil {
		compactBinding := sha256.Sum256(extraData)
		var compactErr error
		quote, compactErr = quoteWithWindowsAK(ak, tpm, compactBinding[:])
		if compactErr != nil {
			return nil, errors.Join(err, fmt.Errorf("compact quote binding failed: %w", compactErr))
		}
	}

	activationID, activationProof, err := maybeActivateWindowsAttestation(
		serverURL,
		clientUID,
		deviceID,
		nonceB64,
		tpm,
		ak,
		params,
		ekPublicSPKIDER,
	)
	if err != nil {
		return nil, err
	}

	return &windowsTPMQuoteMaterial{
		DeviceID:                  deviceID,
		AIKDER:                    aikDER,
		AIKTPMPublic:              append([]byte(nil), params.Public...),
		AKUseTCSDActivationFormat: params.UseTCSDActivationFormat,
		AKCreateData:              append([]byte(nil), params.CreateData...),
		AKCreateAttestation:       append([]byte(nil), params.CreateAttestation...),
		AKCreateSignature:         append([]byte(nil), params.CreateSignature...),
		ActivationID:              activationID,
		ActivationProof:           append([]byte(nil), activationProof...),
		QuoteWire:                 append([]byte(nil), quote.Quote...),
		SignatureWire:             append([]byte(nil), quote.Signature...),
		EKPublicSPKIDER:           ekPublicSPKIDER,
		EKCertDER:                 ekCertDER,
		EKCertificateURL:          strings.TrimSpace(ekCertificateURL),
	}, nil
}

func currentDeviceIdentity() (*deviceIdentity, error) {
	tpm, err := attest.OpenTPM(nil)
	if err != nil {
		return nil, fmt.Errorf("open Windows TPM: %w", err)
	}
	defer tpm.Close()

	ekPublicSPKIDER, _, _, err := readWindowsEndorsementKey(tpm)
	if err != nil {
		return nil, err
	}
	if len(ekPublicSPKIDER) == 0 {
		return nil, fmt.Errorf("Windows endorsement key is unavailable")
	}

	deviceID, err := utils.CanonicalDeviceIDFromPKIXPublicKeyDER(ekPublicSPKIDER)
	if err != nil {
		return nil, fmt.Errorf("derive canonical device_id from Windows EK public key: %w", err)
	}

	return &deviceIdentity{
		ExpectedDeviceID: deviceID,
		DeviceID:         deviceID,
		EKPublicB64:      base64.RawURLEncoding.EncodeToString(ekPublicSPKIDER),
	}, nil
}

func validateCanonicalWindowsDeviceID(claims *attestationClaims) error {
	if claims == nil {
		return fmt.Errorf("attestation payload is missing")
	}
	if claims.Attestation.EKPublicB64 == "" {
		return fmt.Errorf("attestation payload is missing ek_public_b64")
	}
	deviceID, err := utils.CanonicalDeviceIDFromBase64URLPKIXPublicKey(claims.Attestation.EKPublicB64)
	if err != nil {
		return fmt.Errorf("derive canonical device_id from ek_public_b64: %w", err)
	}
	if claims.DeviceID != deviceID {
		return fmt.Errorf("attestation payload device_id did not match ek_public_b64")
	}
	return nil
}

func readWindowsEndorsementKey(tpm *attest.TPM) (ekPublicSPKIDER, ekCertDER []byte, ekCertificateURL string, err error) {
	if tpm == nil {
		return nil, nil, "", nil
	}

	eks, err := tpm.EKs()
	if err != nil {
		return nil, nil, "", fmt.Errorf("read Windows endorsement key: %w", err)
	}
	for _, ek := range eks {
		if ek.Public == nil && (ek.Certificate == nil || len(ek.Certificate.Raw) == 0) {
			continue
		}
		if ek.Public != nil {
			ekPublicSPKIDER, err = x509.MarshalPKIXPublicKey(ek.Public)
			if err != nil {
				return nil, nil, "", fmt.Errorf("marshal Windows EK public key: %w", err)
			}
		}
		if ek.Certificate != nil && len(ek.Certificate.Raw) > 0 {
			ekCertDER = append([]byte(nil), ek.Certificate.Raw...)
		}
		return ekPublicSPKIDER, ekCertDER, strings.TrimSpace(ek.CertificateURL), nil
	}
	return nil, nil, "", nil
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

type attestationActivationRequest struct {
	ClientUID               string `json:"client_uid"`
	DeviceID                string `json:"device_id"`
	Nonce                   string `json:"nonce"`
	AIKTPMPublicB64         string `json:"aik_tpm_public_b64"`
	AIKCreateDataB64        string `json:"aik_create_data_b64"`
	AIKCreateAttestationB64 string `json:"aik_create_attestation_b64"`
	AIKCreateSignatureB64   string `json:"aik_create_signature_b64"`
	UseTCSDActivationFormat bool   `json:"use_tcsd_activation_format,omitempty"`
	EKPublicB64             string `json:"ek_public_b64"`
}

type attestationActivationResponse struct {
	ActivationID  string `json:"activation_id"`
	CredentialB64 string `json:"credential_b64"`
	SecretB64     string `json:"secret_b64"`
	DeviceID      string `json:"device_id"`
	Nonce         string `json:"nonce"`
}

func maybeActivateWindowsAttestation(serverURL, clientUID, deviceID, nonceB64 string, tpm *attest.TPM, ak *attest.AK, params attest.AttestationParameters, ekPublicSPKIDER []byte) (string, []byte, error) {
	if strings.TrimSpace(serverURL) == "" || strings.TrimSpace(clientUID) == "" {
		return "", nil, nil
	}
	if tpm == nil || ak == nil {
		return "", nil, fmt.Errorf("Windows attestation activation requires an open TPM and AK")
	}
	if len(ekPublicSPKIDER) == 0 {
		return "", nil, fmt.Errorf("Windows attestation activation requires ek_public_b64")
	}

	requestBody, err := json.Marshal(attestationActivationRequest{
		ClientUID:               strings.TrimSpace(clientUID),
		DeviceID:                normalizeDeviceID(deviceID),
		Nonce:                   strings.TrimSpace(nonceB64),
		AIKTPMPublicB64:         base64.RawURLEncoding.EncodeToString(params.Public),
		AIKCreateDataB64:        base64.RawURLEncoding.EncodeToString(params.CreateData),
		AIKCreateAttestationB64: base64.RawURLEncoding.EncodeToString(params.CreateAttestation),
		AIKCreateSignatureB64:   base64.RawURLEncoding.EncodeToString(params.CreateSignature),
		UseTCSDActivationFormat: params.UseTCSDActivationFormat,
		EKPublicB64:             base64.RawURLEncoding.EncodeToString(ekPublicSPKIDER),
	})
	if err != nil {
		return "", nil, fmt.Errorf("encode attestation activation request: %w", err)
	}

	endpoint := deriveAttestationActivationEndpoint(serverURL)
	responseBody, err := postJSON(endpoint, requestBody)
	if err != nil {
		return "", nil, err
	}

	var response attestationActivationResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return "", nil, fmt.Errorf("decode attestation activation response from %s: %w", endpoint, err)
	}
	response.ActivationID = strings.TrimSpace(response.ActivationID)
	response.CredentialB64 = strings.TrimSpace(response.CredentialB64)
	response.SecretB64 = strings.TrimSpace(response.SecretB64)
	response.DeviceID = normalizeDeviceID(response.DeviceID)
	response.Nonce = strings.TrimSpace(response.Nonce)
	if response.ActivationID == "" || response.CredentialB64 == "" || response.SecretB64 == "" {
		return "", nil, fmt.Errorf("attestation activation response from %s was incomplete", endpoint)
	}
	if response.DeviceID != "" && response.DeviceID != normalizeDeviceID(deviceID) {
		return "", nil, fmt.Errorf("attestation activation response from %s was issued for device_id=%s instead of %s", endpoint, response.DeviceID, normalizeDeviceID(deviceID))
	}
	if response.Nonce != "" && response.Nonce != strings.TrimSpace(nonceB64) {
		return "", nil, fmt.Errorf("attestation activation response from %s was issued for a different nonce", endpoint)
	}

	credential, err := decodeBase64URL(response.CredentialB64)
	if err != nil || len(credential) == 0 {
		return "", nil, fmt.Errorf("credential_b64 from %s was not valid base64url", endpoint)
	}
	secret, err := decodeBase64URL(response.SecretB64)
	if err != nil || len(secret) == 0 {
		return "", nil, fmt.Errorf("secret_b64 from %s was not valid base64url", endpoint)
	}

	proof, err := ak.ActivateCredential(tpm, attest.EncryptedCredential{
		Credential: credential,
		Secret:     secret,
	})
	if err != nil {
		return "", nil, fmt.Errorf("activate Windows attestation credential: %w", err)
	}
	if len(proof) == 0 {
		return "", nil, fmt.Errorf("Windows attestation activation returned an empty proof")
	}

	return response.ActivationID, proof, nil
}

func postJSON(endpoint string, requestBody []byte) ([]byte, error) {
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(requestBody))
	if err != nil {
		return nil, fmt.Errorf("build JSON request to %s: %w", endpoint, err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("JSON request to %s failed: %w", endpoint, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read JSON response from %s: %w", endpoint, err)
	}
	if resp.StatusCode != http.StatusOK {
		detail := strings.TrimSpace(string(body))
		if detail == "" {
			detail = resp.Status
		}
		return nil, fmt.Errorf("JSON request to %s failed: %s", endpoint, detail)
	}
	return body, nil
}

func deriveAttestationActivationEndpoint(serverURL string) string {
	trimmed := strings.TrimSpace(serverURL)
	trimmed = strings.TrimRight(trimmed, "/")
	if prefix, ok := strings.CutSuffix(trimmed, "/scep"); ok {
		return prefix + "/api/attestation/activation/start"
	}
	return trimmed + "/api/attestation/activation/start"
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
