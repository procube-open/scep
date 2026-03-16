package scepserver

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/procube-open/scep/scep"
)

func TestChallengeMiddleware(t *testing.T) {
	testPW := "RIGHT"
	signer := StaticChallengeMiddleware(testPW, NopCSRSigner())

	csrReq := &scep.CSRReqMessage{ChallengePassword: testPW}

	ctx := context.Background()

	_, err := signer.SignCSRContext(ctx, csrReq)
	if err != nil {
		t.Error(err)
	}

	csrReq.ChallengePassword = "WRONG"

	_, err = signer.SignCSRContext(ctx, csrReq)
	if err == nil {
		t.Error("invalid challenge should generate an error")
	}
}

func TestAttestationMiddleware(t *testing.T) {
	signer := AttestationMiddleware(Base64URLJSONAttestationVerifier(), NopCSRSigner())
	csrReq := &scep.CSRReqMessage{}
	postCtx := ContextWithRequestMethod(context.Background(), "POST")

	if _, err := signer.SignCSRContext(postCtx, csrReq); err != nil {
		t.Fatalf("missing attestation should not fail: %v", err)
	}

	ctx := ContextWithAttestation(
		postCtx,
		base64.RawURLEncoding.EncodeToString([]byte(`{"device_id":"ok"}`)),
	)

	if _, err := signer.SignCSRContext(ctx, csrReq); err != nil {
		t.Fatalf("valid attestation should pass: %v", err)
	}

	invalidCtx := ContextWithAttestation(postCtx, "%%%")
	if _, err := signer.SignCSRContext(invalidCtx, csrReq); err == nil {
		t.Fatal("invalid attestation should generate an error")
	}

	getCtx := ContextWithRequestMethod(context.Background(), "GET")
	if _, err := signer.SignCSRContext(getCtx, csrReq); err != nil {
		t.Fatalf("missing GET attestation should not fail for optional verifier: %v", err)
	}

	getInvalidCtx := ContextWithAttestation(getCtx, "%%%")
	if _, err := signer.SignCSRContext(getInvalidCtx, csrReq); err == nil {
		t.Fatal("invalid GET attestation should generate an error")
	}
}

func TestAttestationMiddlewareInvokesVerifierForGET(t *testing.T) {
	signer := AttestationMiddleware(AttestationVerifierFunc(func(_ context.Context, attestation string) error {
		if attestation == "" {
			return ErrMissingAttestation
		}
		return nil
	}), NopCSRSigner())

	getCtx := ContextWithRequestMethod(context.Background(), "GET")
	if _, err := signer.SignCSRContext(getCtx, &scep.CSRReqMessage{}); !errors.Is(err, ErrMissingAttestation) {
		t.Fatalf("expected verifier to run for GET and return ErrMissingAttestation, got %v", err)
	}
}

func TestDecodeAttestation(t *testing.T) {
	tests := []struct {
		name        string
		attestation string
		wantDevice  string
		wantNonce   string
		wantErr     error
	}{
		{
			name:        "missing attestation",
			attestation: "",
			wantErr:     ErrMissingAttestation,
		},
		{
			name:        "malformed base64",
			attestation: "%%%",
			wantErr:     ErrInvalidAttestation,
		},
		{
			name:        "invalid json",
			attestation: base64.RawURLEncoding.EncodeToString([]byte("{")),
			wantErr:     ErrInvalidAttestation,
		},
		{
			name:        "missing device id",
			attestation: base64.RawURLEncoding.EncodeToString([]byte(`{}`)),
			wantErr:     ErrInvalidAttestation,
		},
		{
			name:        "valid raw base64url",
			attestation: base64.RawURLEncoding.EncodeToString([]byte(`{"device_id":" test-device "}`)),
			wantDevice:  "test-device",
		},
		{
			name:        "valid structured payload",
			attestation: base64.RawURLEncoding.EncodeToString([]byte(`{"device_id":" TEST-DEVICE ","key":{"public_key_spki_b64":"YWJj"},"attestation":{"nonce":"nonce-123"}}`)),
			wantDevice:  "test-device",
			wantNonce:   "nonce-123",
		},
		{
			name:        "valid padded base64url",
			attestation: base64.URLEncoding.EncodeToString([]byte(`{"device_id":"test-device-2"}`)),
			wantDevice:  "test-device-2",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			claims, err := decodeAttestation(tt.attestation)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if claims.DeviceID != tt.wantDevice {
				t.Fatalf("want device_id %q, got %q", tt.wantDevice, claims.DeviceID)
			}
			if claims.Attestation.Nonce != tt.wantNonce {
				t.Fatalf("want nonce %q, got %q", tt.wantNonce, claims.Attestation.Nonce)
			}
		})
	}
}

func TestLookupDeviceID(t *testing.T) {
	tests := []struct {
		name       string
		attributes map[string]interface{}
		wantID     string
		wantOK     bool
	}{
		{
			name:       "nil attributes",
			attributes: nil,
			wantID:     "",
			wantOK:     false,
		},
		{
			name:       "missing device_id",
			attributes: map[string]interface{}{"foo": "bar"},
			wantID:     "",
			wantOK:     false,
		},
		{
			name:       "device_id not string",
			attributes: map[string]interface{}{"device_id": 123},
			wantID:     "",
			wantOK:     false,
		},
		{
			name:       "device_id empty after trim",
			attributes: map[string]interface{}{"device_id": "  "},
			wantID:     "",
			wantOK:     false,
		},
		{
			name:       "valid device_id",
			attributes: map[string]interface{}{"device_id": " test-device "},
			wantID:     "test-device",
			wantOK:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotID, gotOK := lookupDeviceID(tt.attributes)
			if gotOK != tt.wantOK {
				t.Fatalf("want ok %v, got %v", tt.wantOK, gotOK)
			}
			if gotID != tt.wantID {
				t.Fatalf("want device_id %q, got %q", tt.wantID, gotID)
			}
		})
	}
}

func TestAttestationMiddlewareProvidesCSRPublicKey(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{}, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.ParseCertificateRequest(csrDER)
	if err != nil {
		t.Fatal(err)
	}
	wantPublicKey, err := x509.MarshalPKIXPublicKey(csr.PublicKey)
	if err != nil {
		t.Fatal(err)
	}

	verifier := AttestationVerifierFunc(func(ctx context.Context, _ string) error {
		havePublicKey, ok := CSRPublicKeyFromContext(ctx)
		if !ok {
			t.Fatal("expected CSR public key in context")
		}
		if string(havePublicKey) != string(wantPublicKey) {
			t.Fatal("unexpected CSR public key")
		}
		return nil
	})

	signer := AttestationMiddleware(verifier, NopCSRSigner())
	ctx := ContextWithRequestMethod(context.Background(), "POST")
	ctx = ContextWithAttestation(ctx, base64.RawURLEncoding.EncodeToString([]byte(`{"device_id":"device-1"}`)))

	if _, err := signer.SignCSRContext(ctx, &scep.CSRReqMessage{CSR: csr}); err != nil {
		t.Fatalf("expected attestation middleware to pass with CSR key in context: %v", err)
	}
}

func TestVerifyAttestedPublicKeyRequiresBindingWhenConfigured(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}

	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{}, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.ParseCertificateRequest(csrDER)
	if err != nil {
		t.Fatal(err)
	}
	publicKey, err := x509.MarshalPKIXPublicKey(csr.PublicKey)
	if err != nil {
		t.Fatal(err)
	}

	ctx := ContextWithCSRPublicKey(context.Background(), publicKey)

	if err := verifyAttestedPublicKey(ctx, &attestationClaims{}, true); !errors.Is(err, ErrInvalidAttestation) {
		t.Fatalf("expected invalid attestation for missing public key binding, got %v", err)
	}

	claims := &attestationClaims{
		Key: attestationKey{
			PublicKeySPKIB64: base64.RawURLEncoding.EncodeToString(publicKey),
		},
	}
	if err := verifyAttestedPublicKey(ctx, claims, true); err != nil {
		t.Fatalf("expected matching bound public key to pass, got %v", err)
	}
}
