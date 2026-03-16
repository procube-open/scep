package scepserver

import (
	"testing"
	"time"
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
