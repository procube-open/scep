package scepserver

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/utils"
)

func TestAttestationActivationServiceVerifyAndConsume(t *testing.T) {
	service := NewAttestationActivationService(time.Minute)
	service.records["activation-001"] = attestationActivationRecord{
		ClientUID: "client-001",
		DeviceID:  "device-001",
		Nonce:     "nonce-001",
		Secret:    []byte("proof-001"),
		ExpiresAt: time.Now().Add(time.Minute),
	}

	if !service.VerifyAndConsume("client-001", "device-001", "nonce-001", "activation-001", []byte("proof-001")) {
		t.Fatal("expected activation proof to verify")
	}
	if service.VerifyAndConsume("client-001", "device-001", "nonce-001", "activation-001", []byte("proof-001")) {
		t.Fatal("expected activation proof replay to fail")
	}
}

func TestMySQLDeviceIDAttestationVerifierAcceptsValidActivationProof(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	deviceID, ekPublicB64 := newWindowsManagedDeviceID(t)

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", deviceID)
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, deviceID, nonce, enrollmentPublicKey)
	claims.Attestation.EKPublicB64 = ekPublicB64
	claims.Attestation.ActivationID = "activation-001"
	claims.Attestation.ActivationProofB64 = base64.RawURLEncoding.EncodeToString([]byte("proof-001"))

	activations := NewAttestationActivationService(time.Minute)
	activations.records["activation-001"] = attestationActivationRecord{
		ClientUID: "client-001",
		DeviceID:  deviceID,
		Nonce:     nonce,
		Secret:    []byte("proof-001"),
		ExpiresAt: time.Now().Add(time.Minute),
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:          deviceID,
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces, activations)
	if err := verifier(ctx, mustMarshalAttestationClaims(t, claims)); err != nil {
		t.Fatalf("expected activation proof to verify, got %v", err)
	}
	if nonces.Consume("client-001", deviceID, nonce) {
		t.Fatal("expected successful verification to consume nonce")
	}
	if activations.VerifyAndConsume("client-001", deviceID, nonce, "activation-001", []byte("proof-001")) {
		t.Fatal("expected successful verification to consume activation proof")
	}
}

func TestMySQLDeviceIDAttestationVerifierRejectsInvalidActivationProof(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	deviceID, ekPublicB64 := newWindowsManagedDeviceID(t)

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", deviceID)
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, deviceID, nonce, enrollmentPublicKey)
	claims.Attestation.EKPublicB64 = ekPublicB64
	claims.Attestation.ActivationID = "activation-001"
	claims.Attestation.ActivationProofB64 = base64.RawURLEncoding.EncodeToString([]byte("wrong-proof"))

	activations := NewAttestationActivationService(time.Minute)
	activations.records["activation-001"] = attestationActivationRecord{
		ClientUID: "client-001",
		DeviceID:  deviceID,
		Nonce:     nonce,
		Secret:    []byte("proof-001"),
		ExpiresAt: time.Now().Add(time.Minute),
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:          deviceID,
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces, activations)
	err = verifier(ctx, mustMarshalAttestationClaims(t, claims))
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid_activation_proof") {
		t.Fatalf("expected invalid_activation_proof, got %v", err)
	}
	if !nonces.Consume("client-001", deviceID, nonce) {
		t.Fatal("expected invalid activation proof to leave nonce unconsumed")
	}
	if activations.VerifyAndConsume("client-001", deviceID, nonce, "activation-001", []byte("proof-001")) {
		t.Fatal("expected invalid activation proof to consume the stored challenge")
	}
}

func TestMySQLDeviceIDAttestationVerifierRequiresActivationWhenConfigured(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	deviceID, ekPublicB64 := newWindowsManagedDeviceID(t)

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", deviceID)
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, deviceID, nonce, enrollmentPublicKey)
	claims.Attestation.EKPublicB64 = ekPublicB64

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:          deviceID,
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces, NewAttestationActivationService(time.Minute))
	err = verifier(ctx, mustMarshalAttestationClaims(t, claims))
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "missing_activation_proof") {
		t.Fatalf("expected missing_activation_proof, got %v", err)
	}
	if !nonces.Consume("client-001", deviceID, nonce) {
		t.Fatal("expected missing activation proof to leave nonce unconsumed")
	}
}

func TestMySQLDeviceIDAttestationVerifierRejectsMismatchedEKDeviceID(t *testing.T) {
	enrollmentKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	enrollmentPublicKey, err := x509.MarshalPKIXPublicKey(enrollmentKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	registeredEK, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	registeredEKDER, err := x509.MarshalPKIXPublicKey(registeredEK.Public())
	if err != nil {
		t.Fatal(err)
	}
	deviceID, err := utils.CanonicalDeviceIDFromPKIXPublicKeyDER(registeredEKDER)
	if err != nil {
		t.Fatal(err)
	}

	mismatchedEK, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	mismatchedEKDER, err := x509.MarshalPKIXPublicKey(mismatchedEK.Public())
	if err != nil {
		t.Fatal(err)
	}

	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", deviceID)
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, deviceID, nonce, enrollmentPublicKey)
	claims.Attestation.EKPublicB64 = base64.RawURLEncoding.EncodeToString(mismatchedEKDER)
	claims.Attestation.ActivationID = "activation-001"
	claims.Attestation.ActivationProofB64 = base64.RawURLEncoding.EncodeToString([]byte("proof-001"))

	activations := NewAttestationActivationService(time.Minute)
	activations.records["activation-001"] = attestationActivationRecord{
		ClientUID: "client-001",
		DeviceID:  deviceID,
		Nonce:     nonce,
		Secret:    []byte("proof-001"),
		ExpiresAt: time.Now().Add(time.Minute),
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "PENDING",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:          deviceID,
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
	}

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	ctx = ContextWithCSRPublicKey(ctx, enrollmentPublicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces, activations)
	err = verifier(ctx, mustMarshalAttestationClaims(t, claims))
	if !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation, got %v", err)
	}
	if !strings.Contains(err.Error(), "device_id_mismatch") {
		t.Fatalf("expected device_id_mismatch, got %v", err)
	}
	if !nonces.Consume("client-001", deviceID, nonce) {
		t.Fatal("expected mismatched EK device_id to leave nonce unconsumed")
	}
}

func newWindowsManagedDeviceID(t *testing.T) (string, string) {
	t.Helper()

	ekKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	ekDER, err := x509.MarshalPKIXPublicKey(ekKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	deviceID, err := utils.CanonicalDeviceIDFromPKIXPublicKeyDER(ekDER)
	if err != nil {
		t.Fatal(err)
	}
	return deviceID, base64.RawURLEncoding.EncodeToString(ekDER)
}
