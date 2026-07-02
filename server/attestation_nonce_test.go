package scepserver

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/utils"
)

func TestAttestationNonceServiceIssueAndConsume(t *testing.T) {
	nonces := NewAttestationNonceService(time.Minute)
	nonce, expiresAt, err := nonces.Issue("client-1", "DEVICE-1")
	if err != nil {
		t.Fatalf("issue nonce: %v", err)
	}
	if nonce == "" {
		t.Fatal("expected nonce")
	}
	if expiresAt.IsZero() {
		t.Fatal("expected expiry")
	}

	if !nonces.Consume("client-1", "device-1", nonce) {
		t.Fatal("expected nonce to be consumed")
	}
	if nonces.Consume("client-1", "device-1", nonce) {
		t.Fatal("expected nonce replay to fail")
	}
}

func TestAttestationNonceServiceRejectsMismatchedDeviceID(t *testing.T) {
	nonces := NewAttestationNonceService(time.Minute)
	nonce, _, err := nonces.Issue("client-1", "device-1")
	if err != nil {
		t.Fatalf("issue nonce: %v", err)
	}

	if nonces.Consume("client-1", "device-2", nonce) {
		t.Fatal("expected mismatched device_id to fail")
	}
}

func TestAttestationNonceHandlerUsesCanonicalEKDeviceIDForWindowsMSI(t *testing.T) {
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

	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "ISSUABLE",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID:          deviceID,
					utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
				},
			},
		},
	}
	nonces := NewAttestationNonceService(time.Minute)
	handler := NewAttestationNonceHandler(depot, nonces)

	body, err := json.Marshal(AttestationNonceRequest{
		ClientUID:   "client-001",
		DeviceID:    deviceID,
		EKPublicB64: base64.RawURLEncoding.EncodeToString(ekDER),
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/attestation/nonce", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	handler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want status %d, got %d: %s", http.StatusOK, rec.Code, rec.Body.String())
	}

	var response AttestationNonceResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.DeviceID != deviceID {
		t.Fatalf("want device_id %q, got %q", deviceID, response.DeviceID)
	}
	if !nonces.Has("client-001", deviceID, response.Nonce) {
		t.Fatal("expected issued nonce to be stored with canonical device_id")
	}
}

func TestAttestationPreregCheckHandlerReportsNotIssuableYet(t *testing.T) {
	depot := &stubChallengeStore{
		clients: map[string]*mysql.Client{
			"client-001": {
				Uid:    "client-001",
				Status: "INACTIVE",
				Attributes: map[string]interface{}{
					utils.ClientAttributeDeviceID: "device-001",
				},
			},
		},
	}

	body, err := json.Marshal(AttestationPreregCheckRequest{
		ClientUID: "client-001",
		DeviceID:  "device-001",
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/attestation/prereg-check", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	NewAttestationPreregCheckHandler(depot, nil)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want status %d, got %d: %s", http.StatusOK, rec.Code, rec.Body.String())
	}

	var response AttestationPreregCheckResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Result != preregCheckResultNotIssuableYet {
		t.Fatalf("want result %q, got %q", preregCheckResultNotIssuableYet, response.Result)
	}
}

func TestAttestationPreregCheckRateLimiter(t *testing.T) {
	limiter := NewAttestationPreregCheckRateLimiter(2, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	limiter.now = func() time.Time { return now }

	if !limiter.Allow("127.0.0.1") {
		t.Fatal("expected first request to pass")
	}
	if !limiter.Allow("127.0.0.1") {
		t.Fatal("expected second request to pass")
	}
	if limiter.Allow("127.0.0.1") {
		t.Fatal("expected third request to be rate-limited")
	}

	now = now.Add(time.Minute + time.Second)
	if !limiter.Allow("127.0.0.1") {
		t.Fatal("expected limiter window to reset")
	}
}
