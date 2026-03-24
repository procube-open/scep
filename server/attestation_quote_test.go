package scepserver

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/utils"
)

func TestVerifyTPMQuoteAttestationAcceptsCanonicalFormat(t *testing.T) {
	claims := newCanonicalTPMAttestationClaims(t, "device-001")

	if err := verifyTPMQuoteAttestation(claims); err != nil {
		t.Fatalf("expected canonical TPM attestation to verify, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationAcceptsCompactExtraData(t *testing.T) {
	attestedKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	attestedPublicKey, err := x509.MarshalPKIXPublicKey(attestedKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithBindingMode(
		t,
		"device-001",
		base64.RawURLEncoding.EncodeToString([]byte("quote-nonce")),
		attestedPublicKey,
		true,
	)

	if err := verifyTPMQuoteAttestation(claims); err != nil {
		t.Fatalf("expected compact TPM attestation to verify, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationAllowsPlaceholderWithoutQuote(t *testing.T) {
	claims := &attestationClaims{
		DeviceID: "device-001",
		Attestation: attestationBundle{
			Format: "tpm2-windows-v1-placeholder-initial",
			Nonce:  "placeholder-nonce",
		},
	}

	if err := verifyTPMQuoteAttestation(claims); err != nil {
		t.Fatalf("expected placeholder attestation without quote material to pass, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationAllowsLegacyNonceKeyBindingFormat(t *testing.T) {
	claims := &attestationClaims{
		DeviceID: "device-001",
		Attestation: attestationBundle{
			Format: legacyNonceKeyBindingAttestationFmt,
			Nonce:  base64.RawURLEncoding.EncodeToString([]byte("nonce")),
		},
	}

	if err := verifyTPMQuoteAttestation(claims); err != nil {
		t.Fatalf("expected legacy nonce/key binding attestation to pass, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationRejectsBlankFormat(t *testing.T) {
	claims := &attestationClaims{
		DeviceID: "device-001",
		Attestation: attestationBundle{
			Nonce: base64.RawURLEncoding.EncodeToString([]byte("nonce")),
		},
	}

	err := verifyTPMQuoteAttestation(claims)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid_attestation_format") {
		t.Fatalf("expected invalid_attestation_format, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationRejectsUnknownFormat(t *testing.T) {
	claims := &attestationClaims{
		DeviceID: "device-001",
		Attestation: attestationBundle{
			Format: "tpm2-windows-v1-unknown",
			Nonce:  base64.RawURLEncoding.EncodeToString([]byte("nonce")),
		},
	}

	err := verifyTPMQuoteAttestation(claims)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid_attestation_format") {
		t.Fatalf("expected invalid_attestation_format, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationRejectsMissingQuoteFields(t *testing.T) {
	claims := &attestationClaims{
		DeviceID: "device-001",
		Attestation: attestationBundle{
			Format: canonicalWindowsTPMAttestationFormat,
			Nonce:  base64.RawURLEncoding.EncodeToString([]byte("nonce")),
		},
	}

	err := verifyTPMQuoteAttestation(claims)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid_attestation_format") {
		t.Fatalf("expected invalid_attestation_format, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationRejectsNonceMismatch(t *testing.T) {
	claims := newCanonicalTPMAttestationClaims(t, "device-001")
	claims.Attestation.Nonce = base64.RawURLEncoding.EncodeToString([]byte("othernonce1"))

	err := verifyTPMQuoteAttestation(claims)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "nonce_mismatch") {
		t.Fatalf("expected nonce_mismatch, got %v", err)
	}
}

func TestVerifyTPMQuoteAttestationRejectsQuotePublicKeyMismatch(t *testing.T) {
	claims := newCanonicalTPMAttestationClaims(t, "device-001")
	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	otherPublicKey, err := x509.MarshalPKIXPublicKey(otherKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	claims.Key.PublicKeySPKIB64 = base64.RawURLEncoding.EncodeToString(otherPublicKey)

	err = verifyTPMQuoteAttestation(claims)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "public_key_mismatch") {
		t.Fatalf("expected public_key_mismatch, got %v", err)
	}
}

func TestMySQLDeviceIDAttestationVerifierRejectsInvalidQuoteSignature(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					"device_id": "device-001",
				},
			},
		},
	}
	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", "device-001")
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, "device-001", nonce, enrollmentPublicKey)
	signatureBlob, err := decodeBase64URL(claims.Attestation.QuoteSignatureB64)
	if err != nil {
		t.Fatal(err)
	}
	signatureBlob[len(signatureBlob)-1] ^= 0xFF
	claims.Attestation.QuoteSignatureB64 = base64.RawURLEncoding.EncodeToString(signatureBlob)

	attestationJSON, err := marshalAttestationClaims(claims)
	if err != nil {
		t.Fatal(err)
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces)
	err = verifier(ctx, attestationJSON)
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid_quote_signature") {
		t.Fatalf("expected invalid_quote_signature, got %v", err)
	}
	if !nonces.Consume("client-001", "device-001", nonce) {
		t.Fatal("expected invalid quote signature to leave nonce unconsumed")
	}
}

func TestMySQLDeviceIDAttestationVerifierAcceptsPinnedAIKAndEKCert(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", "device-001")
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, "device-001", nonce, enrollmentPublicKey)
	claims.Attestation.EKCertB64 = base64.RawURLEncoding.EncodeToString(newTestCertificateDER(t, "ek-match"))

	aikFingerprint, err := sha256FingerprintOfBase64URLPKIXPublicKey(claims.Attestation.AIKPublicB64)
	if err != nil {
		t.Fatal(err)
	}
	ekFingerprint, err := sha256FingerprintOfBase64URLCertificate(claims.Attestation.EKCertB64)
	if err != nil {
		t.Fatal(err)
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:                 "device-001",
					utils.ClientAttributeAttestationAIKSPKISHA256: aikFingerprint,
					utils.ClientAttributeAttestationEKCertSHA256:  ekFingerprint,
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces)
	if err := verifier(ctx, mustMarshalAttestationClaims(t, claims)); err != nil {
		t.Fatalf("expected pinned AIK/EK verification to succeed, got %v", err)
	}
	if nonces.Consume("client-001", "device-001", nonce) {
		t.Fatal("expected successful verification to consume nonce")
	}
}

func TestMySQLDeviceIDAttestationVerifierRejectsPinnedAIKMismatch(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", "device-001")
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, "device-001", nonce, enrollmentPublicKey)
	otherAIK, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	otherAIKPublicDER, err := x509.MarshalPKIXPublicKey(otherAIK.Public())
	if err != nil {
		t.Fatal(err)
	}
	expectedAIK := sha256.Sum256(otherAIKPublicDER)

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:                 "device-001",
					utils.ClientAttributeAttestationAIKSPKISHA256: fmt.Sprintf("%x", expectedAIK[:]),
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces)
	err = verifier(ctx, mustMarshalAttestationClaims(t, claims))
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "aik_public_mismatch") {
		t.Fatalf("expected aik_public_mismatch, got %v", err)
	}
	if !nonces.Consume("client-001", "device-001", nonce) {
		t.Fatal("expected AIK mismatch to leave nonce unconsumed")
	}
}

func TestMySQLDeviceIDAttestationVerifierRejectsPinnedEKCertMismatch(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", "device-001")
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, "device-001", nonce, enrollmentPublicKey)
	claims.Attestation.EKCertB64 = base64.RawURLEncoding.EncodeToString(newTestCertificateDER(t, "ek-actual"))
	expectedEKCert := sha256.Sum256(newTestCertificateDER(t, "ek-other"))

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:                "device-001",
					utils.ClientAttributeAttestationEKCertSHA256: fmt.Sprintf("%x", expectedEKCert[:]),
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces)
	err = verifier(ctx, mustMarshalAttestationClaims(t, claims))
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "ek_cert_mismatch") {
		t.Fatalf("expected ek_cert_mismatch, got %v", err)
	}
	if !nonces.Consume("client-001", "device-001", nonce) {
		t.Fatal("expected EK cert mismatch to leave nonce unconsumed")
	}
}

func newCanonicalTPMAttestationClaims(t *testing.T, deviceID string) *attestationClaims {
	t.Helper()

	attestedKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	attestedPublicKey, err := x509.MarshalPKIXPublicKey(attestedKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	return newCanonicalTPMAttestationClaimsWithNonce(
		t,
		deviceID,
		base64.RawURLEncoding.EncodeToString([]byte("quote-nonce")),
		attestedPublicKey,
	)
}

func newCanonicalTPMAttestationClaimsWithNonce(t *testing.T, deviceID, nonce string, attestedPublicKey []byte) *attestationClaims {
	return newCanonicalTPMAttestationClaimsWithBindingMode(t, deviceID, nonce, attestedPublicKey, false)
}

func newCanonicalTPMAttestationClaimsWithBindingMode(t *testing.T, deviceID, nonce string, attestedPublicKey []byte, compact bool) *attestationClaims {
	t.Helper()

	aikKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	aikPublicDER, err := x509.MarshalPKIXPublicKey(aikKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	quoteWire, signedQuote := buildTestTPMQuote(t, nonce, attestedPublicKey, compact)
	signatureBlob := buildTestTPMRSASSASignature(t, aikKey, signedQuote)

	return &attestationClaims{
		DeviceID: deviceID,
		Key: attestationKey{
			PublicKeySPKIB64: base64.RawURLEncoding.EncodeToString(attestedPublicKey),
		},
		Attestation: attestationBundle{
			Format:            canonicalWindowsTPMAttestationFormat,
			Nonce:             nonce,
			AIKPublicB64:      base64.RawURLEncoding.EncodeToString(aikPublicDER),
			QuoteB64:          base64.RawURLEncoding.EncodeToString(quoteWire),
			QuoteSignatureB64: base64.RawURLEncoding.EncodeToString(signatureBlob),
		},
	}
}

func buildTestTPMQuote(t *testing.T, nonce string, attestedPublicKey []byte, compact bool) ([]byte, []byte) {
	t.Helper()

	quoteNonce, err := decodeBase64URL(nonce)
	if err != nil {
		t.Fatal(err)
	}
	publicKeyDigest := sha256.Sum256(attestedPublicKey)
	extraData := append(publicKeyDigest[:], quoteNonce...)
	if compact {
		compactDigest := sha256.Sum256(extraData)
		extraData = compactDigest[:]
	}

	payload := new(bytes.Buffer)
	mustWriteBinary(t, payload, uint32(tpmGeneratedValue))
	mustWriteBinary(t, payload, uint16(tpmSTAttestQuote))
	writeTPM2B(t, payload, nil)
	writeTPM2B(t, payload, extraData)
	mustWriteBinary(t, payload, uint64(0))
	mustWriteBinary(t, payload, uint32(0))
	mustWriteBinary(t, payload, uint32(0))
	if err := payload.WriteByte(1); err != nil {
		t.Fatal(err)
	}
	mustWriteBinary(t, payload, uint64(0))
	mustWriteBinary(t, payload, uint32(0))
	writeTPM2B(t, payload, nil)

	wire := new(bytes.Buffer)
	mustWriteBinary(t, wire, uint16(payload.Len()))
	if _, err := wire.Write(payload.Bytes()); err != nil {
		t.Fatal(err)
	}

	return wire.Bytes(), payload.Bytes()
}

func buildTestTPMRSASSASignature(t *testing.T, privateKey *rsa.PrivateKey, signedQuote []byte) []byte {
	t.Helper()

	digest := sha256.Sum256(signedQuote)
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}

	blob := new(bytes.Buffer)
	mustWriteBinary(t, blob, uint16(tpmAlgRSASSA))
	mustWriteBinary(t, blob, uint16(tpmAlgSHA256))
	writeTPM2B(t, blob, signature)
	return blob.Bytes()
}

func marshalAttestationClaims(claims *attestationClaims) (string, error) {
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(payload), nil
}

func mustMarshalAttestationClaims(t *testing.T, claims *attestationClaims) string {
	t.Helper()

	payload, err := marshalAttestationClaims(claims)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func writeTPM2B(t *testing.T, buffer *bytes.Buffer, payload []byte) {
	t.Helper()
	mustWriteBinary(t, buffer, uint16(len(payload)))
	if _, err := buffer.Write(payload); err != nil {
		t.Fatal(err)
	}
}

func mustWriteBinary(t *testing.T, buffer *bytes.Buffer, value interface{}) {
	t.Helper()
	if err := binary.Write(buffer, binary.BigEndian, value); err != nil {
		t.Fatal(err)
	}
}

func newTestCertificateDER(t *testing.T, commonName string) []byte {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject: pkix.Name{
			CommonName: commonName,
		},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, privateKey.Public(), privateKey)
	if err != nil {
		t.Fatal(err)
	}
	return der
}
