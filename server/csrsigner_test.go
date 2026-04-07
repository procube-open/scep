package scepserver

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/scep"
	"github.com/procube-open/scep/utils"
)

type stubChallengeStore struct {
	clients       map[string]*mysql.Client
	secret        mysql.GetSecretInfo
	getClientErr  error
	getSecretErr  error
	activeCert    bool
	activeCertErr error
}

func (s *stubChallengeStore) GetClient(uid string) (*mysql.Client, error) {
	if s.getClientErr != nil {
		return nil, s.getClientErr
	}
	return s.clients[uid], nil
}

func (s *stubChallengeStore) GetSecret(string) (mysql.GetSecretInfo, error) {
	if s.getSecretErr != nil {
		return mysql.GetSecretInfo{}, s.getSecretErr
	}
	return s.secret, nil
}

func (s *stubChallengeStore) HasActiveCertificate(string, *x509.Certificate) (bool, error) {
	if s.activeCertErr != nil {
		return false, s.activeCertErr
	}
	return s.activeCert, nil
}

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

func TestMySQLChallengeMiddlewareRejectsWindowsMSIChallengeUpdate(t *testing.T) {
	signer := MySQLChallengeMiddleWare(&stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "UPDATABLE",
				Attributes: map[string]interface{}{
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
		secret: mysql.GetSecretInfo{Secret: "secret"},
	}, NopCSRSigner())

	ctx := ContextWithChallengePassword(context.Background(), "client-001\\secret")
	_, err := signer.SignCSRContext(ctx, &scep.CSRReqMessage{})
	if err == nil || err.Error() != "windows-msi client is not issuable" {
		t.Fatalf("expected windows-msi challenge rejection, got %v", err)
	}
}

func TestMySQLChallengeMiddlewareRejectsWindowsMSIRenewalFromUpdatable(t *testing.T) {
	signer := MySQLChallengeMiddleWare(&stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "UPDATABLE",
				Attributes: map[string]interface{}{
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
		activeCert: true,
	}, NopCSRSigner())

	ctx := ContextWithSCEPMessageType(context.Background(), scep.RenewalReq)
	ctx = ContextWithSignerCertificate(ctx, &x509.Certificate{
		Subject: pkix.Name{CommonName: "client-001"},
	})

	_, err := signer.SignCSRContext(ctx, &scep.CSRReqMessage{})
	if err == nil || err.Error() != "windows-msi client is not issued" {
		t.Fatalf("expected windows-msi renewal rejection, got %v", err)
	}
}

func TestDecodeAttestation(t *testing.T) {
	tests := []struct {
		name                string
		attestation         string
		wantDevice          string
		wantNonce           string
		wantAIKTPMPublic    string
		wantActivationID    string
		wantActivationProof string
		wantEKPublic        string
		wantEKURL           string
		wantErr             error
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
			name:                "valid structured payload",
			attestation:         base64.RawURLEncoding.EncodeToString([]byte(`{"device_id":" TEST-DEVICE ","key":{"public_key_spki_b64":"YWJj"},"attestation":{"nonce":"nonce-123","aik_tpm_public_b64":"dHBtLXB1YmxpYw","activation_id":" activation-001 ","activation_proof_b64":" cHJvb2Y ","ek_public_b64":"ZWstcHVibGlj","ek_certificate_url":" https://example.invalid/ek "}}`)),
			wantDevice:          "test-device",
			wantNonce:           "nonce-123",
			wantAIKTPMPublic:    "dHBtLXB1YmxpYw",
			wantActivationID:    "activation-001",
			wantActivationProof: "cHJvb2Y",
			wantEKPublic:        "ZWstcHVibGlj",
			wantEKURL:           "https://example.invalid/ek",
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
			if claims.Attestation.AIKTPMPublicB64 != tt.wantAIKTPMPublic {
				t.Fatalf("want aik_tpm_public_b64 %q, got %q", tt.wantAIKTPMPublic, claims.Attestation.AIKTPMPublicB64)
			}
			if claims.Attestation.ActivationID != tt.wantActivationID {
				t.Fatalf("want activation_id %q, got %q", tt.wantActivationID, claims.Attestation.ActivationID)
			}
			if claims.Attestation.ActivationProofB64 != tt.wantActivationProof {
				t.Fatalf("want activation_proof_b64 %q, got %q", tt.wantActivationProof, claims.Attestation.ActivationProofB64)
			}
			if claims.Attestation.EKPublicB64 != tt.wantEKPublic {
				t.Fatalf("want ek_public_b64 %q, got %q", tt.wantEKPublic, claims.Attestation.EKPublicB64)
			}
			if claims.Attestation.EKCertificateURL != tt.wantEKURL {
				t.Fatalf("want ek_certificate_url %q, got %q", tt.wantEKURL, claims.Attestation.EKCertificateURL)
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

func TestLookupSHA256Fingerprint(t *testing.T) {
	tests := []struct {
		name       string
		attributes map[string]interface{}
		key        string
		want       string
		wantOK     bool
	}{
		{
			name:       "missing fingerprint",
			attributes: map[string]interface{}{},
			key:        utils.ClientAttributeAttestationAIKSPKISHA256,
			wantOK:     false,
		},
		{
			name: "invalid fingerprint",
			attributes: map[string]interface{}{
				utils.ClientAttributeAttestationAIKSPKISHA256: "xyz",
			},
			key:    utils.ClientAttributeAttestationAIKSPKISHA256,
			wantOK: false,
		},
		{
			name: "valid fingerprint with separators",
			attributes: map[string]interface{}{
				utils.ClientAttributeAttestationAIKSPKISHA256: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
			},
			key:    utils.ClientAttributeAttestationAIKSPKISHA256,
			want:   "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
			wantOK: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := lookupSHA256Fingerprint(tt.attributes, tt.key)
			if ok != tt.wantOK {
				t.Fatalf("want ok %v, got %v", tt.wantOK, ok)
			}
			if got != tt.want {
				t.Fatalf("want %q, got %q", tt.want, got)
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

func TestMySQLChallengeMiddlewareAllowsRenewalWithActiveSigner(t *testing.T) {
	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "ISSUED",
			},
		},
		activeCert: true,
	}
	signer := MySQLChallengeMiddleWare(depot, NopCSRSigner())

	ctx := ContextWithSCEPMessageType(context.Background(), scep.RenewalReq)
	ctx = ContextWithSignerCertificate(ctx, &x509.Certificate{
		Subject: pkix.Name{CommonName: "client-001"},
	})

	if _, err := signer.SignCSRContext(ctx, &scep.CSRReqMessage{}); err != nil {
		t.Fatalf("expected renewal signer to authorize request, got %v", err)
	}
}

func TestMySQLChallengeMiddlewareRejectsRenewalWithoutActiveSigner(t *testing.T) {
	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "ISSUED",
			},
		},
	}
	signer := MySQLChallengeMiddleWare(depot, NopCSRSigner())

	ctx := ContextWithSCEPMessageType(context.Background(), scep.RenewalReq)
	ctx = ContextWithSignerCertificate(ctx, &x509.Certificate{
		Subject: pkix.Name{CommonName: "client-001"},
	})

	if _, err := signer.SignCSRContext(ctx, &scep.CSRReqMessage{}); err == nil {
		t.Fatal("expected renewal without active signer certificate to fail")
	}
}

func TestMySQLDeviceIDAttestationVerifierAllowsRenewalSignerIdentity(t *testing.T) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	publicKey, err := x509.MarshalPKIXPublicKey(privateKey.Public())
	if err != nil {
		t.Fatal(err)
	}

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "ISSUED",
				Attributes: map[string]interface{}{
					"device_id": "device-001",
				},
			},
		},
		activeCert: true,
	}
	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-001", "device-001")
	if err != nil {
		t.Fatal(err)
	}

	claims := newCanonicalTPMAttestationClaimsWithNonce(t, "device-001", nonce, publicKey)
	attestation, err := marshalAttestationClaims(claims)
	if err != nil {
		t.Fatal(err)
	}

	ctx := ContextWithSCEPMessageType(context.Background(), scep.RenewalReq)
	ctx = ContextWithSignerCertificate(ctx, &x509.Certificate{
		Subject: pkix.Name{CommonName: "client-001"},
	})
	ctx = ContextWithCSRPublicKey(ctx, publicKey)

	verifier := MySQLDeviceIDAttestationVerifier(depot, nonces, nil)
	if err := verifier(ctx, attestation); err != nil {
		t.Fatalf("expected renewal attestation to pass, got %v", err)
	}
	if nonces.Consume("client-001", "device-001", nonce) {
		t.Fatal("expected attestation verifier to consume nonce")
	}
}
