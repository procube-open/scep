package scepserver

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/scep"
	"github.com/procube-open/scep/utils"
)

var (
	ErrMissingAttestation = errors.New("missing attestation")
	ErrInvalidAttestation = errors.New("invalid attestation")
)

type attestationContextKey struct{}

func ContextWithAttestation(ctx context.Context, attestation string) context.Context {
	return context.WithValue(ctx, attestationContextKey{}, attestation)
}

func AttestationFromContext(ctx context.Context) (string, bool) {
	attestation, ok := ctx.Value(attestationContextKey{}).(string)
	if !ok {
		return "", false
	}
	return attestation, attestation != ""
}

type requestMethodContextKey struct{}

func ContextWithRequestMethod(ctx context.Context, method string) context.Context {
	return context.WithValue(ctx, requestMethodContextKey{}, method)
}

func RequestMethodFromContext(ctx context.Context) (string, bool) {
	method, ok := ctx.Value(requestMethodContextKey{}).(string)
	if !ok {
		return "", false
	}
	return method, method != ""
}

type challengePasswordContextKey struct{}

func ContextWithChallengePassword(ctx context.Context, challenge string) context.Context {
	return context.WithValue(ctx, challengePasswordContextKey{}, challenge)
}

func ChallengePasswordFromContext(ctx context.Context) (string, bool) {
	challenge, ok := ctx.Value(challengePasswordContextKey{}).(string)
	if !ok {
		return "", false
	}
	return challenge, challenge != ""
}

func challengePasswordValueFromContext(ctx context.Context) (string, bool) {
	challenge, ok := ctx.Value(challengePasswordContextKey{}).(string)
	if !ok {
		return "", false
	}
	return challenge, true
}

type csrPublicKeyContextKey struct{}

func ContextWithCSRPublicKey(ctx context.Context, publicKey []byte) context.Context {
	copied := append([]byte(nil), publicKey...)
	return context.WithValue(ctx, csrPublicKeyContextKey{}, copied)
}

func CSRPublicKeyFromContext(ctx context.Context) ([]byte, bool) {
	publicKey, ok := ctx.Value(csrPublicKeyContextKey{}).([]byte)
	if !ok || len(publicKey) == 0 {
		return nil, false
	}

	return append([]byte(nil), publicKey...), true
}

type scepMessageTypeContextKey struct{}

func ContextWithSCEPMessageType(ctx context.Context, messageType scep.MessageType) context.Context {
	return context.WithValue(ctx, scepMessageTypeContextKey{}, messageType)
}

func SCEPMessageTypeFromContext(ctx context.Context) (scep.MessageType, bool) {
	messageType, ok := ctx.Value(scepMessageTypeContextKey{}).(scep.MessageType)
	if !ok {
		return "", false
	}
	return messageType, messageType != ""
}

type signerCertificateContextKey struct{}

func ContextWithSignerCertificate(ctx context.Context, cert *x509.Certificate) context.Context {
	if cert == nil {
		return ctx
	}
	return context.WithValue(ctx, signerCertificateContextKey{}, cert)
}

func SignerCertificateFromContext(ctx context.Context) (*x509.Certificate, bool) {
	cert, ok := ctx.Value(signerCertificateContextKey{}).(*x509.Certificate)
	if !ok || cert == nil {
		return nil, false
	}
	return cert, true
}

type requestClientStore interface {
	GetClient(uid string) (*mysql.Client, error)
	HasActiveCertificate(cn string, cert *x509.Certificate) (bool, error)
}

type requestIdentityAuthMethod int

const (
	requestIdentityByChallenge requestIdentityAuthMethod = iota
	requestIdentityBySignerCertificate
)

type requestIdentity struct {
	client     *mysql.Client
	secret     string
	authMethod requestIdentityAuthMethod
}

func resolveRequestIdentity(ctx context.Context, depot requestClientStore) (*requestIdentity, error) {
	if depot == nil {
		return nil, errors.New("challenge depot is nil")
	}

	if challenge, ok := challengePasswordValueFromContext(ctx); ok {
		challenge = strings.TrimSpace(challenge)
		if challenge != "" {
			arr := strings.SplitN(challenge, "\\", 2)
			if len(arr) != 2 {
				return nil, errors.New("invalid challenge")
			}
			clientUID := strings.TrimSpace(arr[0])
			if clientUID == "" || arr[1] == "" {
				return nil, errors.New("invalid challenge")
			}
			client, err := depot.GetClient(clientUID)
			if err != nil {
				return nil, err
			}
			if client == nil {
				return nil, errors.New("invalid challenge")
			}
			return &requestIdentity{
				client:     client,
				secret:     arr[1],
				authMethod: requestIdentityByChallenge,
			}, nil
		}
	}

	messageType, ok := SCEPMessageTypeFromContext(ctx)
	if !ok || !isRenewalMessageType(messageType) {
		return nil, errors.New("invalid challenge")
	}

	signerCert, ok := SignerCertificateFromContext(ctx)
	if !ok {
		return nil, errors.New("invalid renewal signer")
	}
	clientUID := strings.TrimSpace(signerCert.Subject.CommonName)
	if clientUID == "" {
		return nil, errors.New("invalid renewal signer")
	}

	client, err := depot.GetClient(clientUID)
	if err != nil {
		return nil, err
	}
	if client == nil {
		return nil, errors.New("invalid renewal signer")
	}

	active, err := depot.HasActiveCertificate(clientUID, signerCert)
	if err != nil {
		return nil, err
	}
	if !active {
		return nil, errors.New("invalid renewal signer")
	}

	return &requestIdentity{
		client:     client,
		authMethod: requestIdentityBySignerCertificate,
	}, nil
}

func isRenewalMessageType(messageType scep.MessageType) bool {
	return messageType == scep.RenewalReq || messageType == scep.UpdateReq
}

type AttestationVerifier interface {
	VerifyAttestation(context.Context, string) error
}

type AttestationVerifierFunc func(context.Context, string) error

func (f AttestationVerifierFunc) VerifyAttestation(ctx context.Context, attestation string) error {
	return f(ctx, attestation)
}

func Base64URLJSONAttestationVerifier() AttestationVerifierFunc {
	return func(_ context.Context, attestation string) error {
		if attestation == "" {
			return nil
		}
		_, err := decodeAttestation(attestation)
		return err
	}
}

func MySQLDeviceIDAttestationVerifier(depot requestClientStore, nonces *AttestationNonceService) AttestationVerifierFunc {
	return func(ctx context.Context, attestation string) error {
		if depot == nil {
			return errors.New("attestation depot is nil")
		}

		identity, err := resolveRequestIdentity(ctx, depot)
		if err != nil {
			return err
		}
		client := identity.client

		registeredDeviceID, hasRegisteredDeviceID := lookupDeviceID(client.Attributes)
		if !hasRegisteredDeviceID {
			if attestation == "" {
				return nil
			}
			_, err = decodeAttestation(attestation)
			return err
		}
		if attestation == "" {
			return fmt.Errorf("%w: missing_attestation", ErrMissingAttestation)
		}

		claims, err := decodeAttestation(attestation)
		if err != nil {
			return err
		}
		if claims.DeviceID != registeredDeviceID {
			return fmt.Errorf("%w: device_id_mismatch", ErrInvalidAttestation)
		}
		if err := verifyAttestedPublicKey(ctx, claims, true); err != nil {
			return err
		}
		if err := verifyTPMQuoteAttestation(claims); err != nil {
			return err
		}
		if err := verifyRegisteredAttestationTrust(client.Attributes, claims); err != nil {
			return err
		}
		if nonces != nil {
			if claims.Attestation.Nonce == "" {
				return fmt.Errorf("%w: nonce_mismatch", ErrInvalidAttestation)
			}
			if !nonces.Consume(client.Uid, claims.DeviceID, claims.Attestation.Nonce) {
				return fmt.Errorf("%w: nonce_mismatch", ErrInvalidAttestation)
			}
		}

		return nil
	}
}

type attestationKey struct {
	Algorithm        string `json:"algorithm"`
	Provider         string `json:"provider"`
	PublicKeySPKIB64 string `json:"public_key_spki_b64"`
}

type attestationBundle struct {
	Format            string            `json:"format"`
	Nonce             string            `json:"nonce"`
	AIKPublicB64      string            `json:"aik_public_b64"`
	QuoteB64          string            `json:"quote_b64"`
	QuoteSignatureB64 string            `json:"quote_signature_b64"`
	PCRs              []json.RawMessage `json:"pcrs"`
	EKCertB64         string            `json:"ek_cert_b64"`
}

type attestationMeta struct {
	Hostname    string `json:"hostname"`
	OSVersion   string `json:"os_version"`
	GeneratedAt string `json:"generated_at"`
}

type attestationClaims struct {
	DeviceID    string            `json:"device_id"`
	Key         attestationKey    `json:"key"`
	Attestation attestationBundle `json:"attestation"`
	Meta        attestationMeta   `json:"meta"`
}

func decodeAttestation(attestation string) (*attestationClaims, error) {
	if attestation == "" {
		return nil, ErrMissingAttestation
	}

	payload, err := decodeBase64URL(attestation)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidAttestation, err)
	}

	var claims attestationClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("%w: decoded payload is not valid json", ErrInvalidAttestation)
	}
	claims.DeviceID = utils.NormalizeDeviceID(claims.DeviceID)
	if claims.DeviceID == "" {
		return nil, fmt.Errorf("%w: missing_device_id", ErrInvalidAttestation)
	}
	claims.Key.Algorithm = strings.TrimSpace(claims.Key.Algorithm)
	claims.Key.Provider = strings.TrimSpace(claims.Key.Provider)
	claims.Key.PublicKeySPKIB64 = strings.TrimSpace(claims.Key.PublicKeySPKIB64)
	claims.Attestation.Format = strings.TrimSpace(claims.Attestation.Format)
	claims.Attestation.Nonce = strings.TrimSpace(claims.Attestation.Nonce)
	claims.Attestation.AIKPublicB64 = strings.TrimSpace(claims.Attestation.AIKPublicB64)
	claims.Attestation.QuoteB64 = strings.TrimSpace(claims.Attestation.QuoteB64)
	claims.Attestation.QuoteSignatureB64 = strings.TrimSpace(claims.Attestation.QuoteSignatureB64)
	claims.Attestation.EKCertB64 = strings.TrimSpace(claims.Attestation.EKCertB64)
	claims.Meta.Hostname = strings.TrimSpace(claims.Meta.Hostname)
	claims.Meta.OSVersion = strings.TrimSpace(claims.Meta.OSVersion)
	claims.Meta.GeneratedAt = strings.TrimSpace(claims.Meta.GeneratedAt)
	return &claims, nil
}

func lookupDeviceID(attributes map[string]interface{}) (string, bool) {
	if attributes == nil {
		return "", false
	}

	deviceID, ok := attributes[utils.ClientAttributeDeviceID].(string)
	if !ok {
		return "", false
	}
	deviceID = utils.NormalizeDeviceID(deviceID)
	if deviceID == "" {
		return "", false
	}

	return deviceID, true
}

func lookupSHA256Fingerprint(attributes map[string]interface{}, key string) (string, bool) {
	if attributes == nil {
		return "", false
	}

	value, ok := attributes[key].(string)
	if !ok {
		return "", false
	}
	value = utils.NormalizeSHA256Fingerprint(value)
	if value == "" {
		return "", false
	}
	return value, true
}

func verifyRegisteredAttestationTrust(attributes map[string]interface{}, claims *attestationClaims) error {
	if claims == nil {
		return nil
	}
	if expectedAIK, ok := lookupSHA256Fingerprint(attributes, utils.ClientAttributeAttestationAIKSPKISHA256); ok {
		actualAIK, err := sha256FingerprintOfBase64URLPKIXPublicKey(claims.Attestation.AIKPublicB64)
		if err != nil {
			return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
		}
		if actualAIK != expectedAIK {
			return fmt.Errorf("%w: aik_public_mismatch", ErrInvalidAttestation)
		}
	}
	if expectedEKCert, ok := lookupSHA256Fingerprint(attributes, utils.ClientAttributeAttestationEKCertSHA256); ok {
		actualEKCert, err := sha256FingerprintOfBase64URLCertificate(claims.Attestation.EKCertB64)
		if err != nil {
			return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
		}
		if actualEKCert != expectedEKCert {
			return fmt.Errorf("%w: ek_cert_mismatch", ErrInvalidAttestation)
		}
	}
	return nil
}

func sha256FingerprintOfBase64URLPKIXPublicKey(value string) (string, error) {
	decoded, err := decodeBase64URL(strings.TrimSpace(value))
	if err != nil || len(decoded) == 0 {
		return "", fmt.Errorf("decode public key")
	}
	if _, err := x509.ParsePKIXPublicKey(decoded); err != nil {
		return "", err
	}
	sum := sha256.Sum256(decoded)
	return fmt.Sprintf("%x", sum[:]), nil
}

func sha256FingerprintOfBase64URLCertificate(value string) (string, error) {
	decoded, err := decodeBase64URL(strings.TrimSpace(value))
	if err != nil || len(decoded) == 0 {
		return "", fmt.Errorf("decode certificate")
	}
	if _, err := x509.ParseCertificate(decoded); err != nil {
		return "", err
	}
	sum := sha256.Sum256(decoded)
	return fmt.Sprintf("%x", sum[:]), nil
}

func verifyAttestedPublicKey(ctx context.Context, claims *attestationClaims, required bool) error {
	if claims == nil {
		return nil
	}
	if claims.Key.PublicKeySPKIB64 == "" {
		if required {
			return fmt.Errorf("%w: public_key_mismatch", ErrInvalidAttestation)
		}
		return nil
	}

	attestedPublicKey, err := decodeBase64URL(claims.Key.PublicKeySPKIB64)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	if _, err := x509.ParsePKIXPublicKey(attestedPublicKey); err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}

	csrPublicKey, ok := CSRPublicKeyFromContext(ctx)
	if !ok || !bytes.Equal(attestedPublicKey, csrPublicKey) {
		return fmt.Errorf("%w: public_key_mismatch", ErrInvalidAttestation)
	}

	return nil
}

func decodeBase64URL(payload string) ([]byte, error) {
	if decoded, err := base64.RawURLEncoding.DecodeString(payload); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(payload)
}
