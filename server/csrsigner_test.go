package scepserver

import (
	"context"
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
	getCtx = ContextWithAttestation(getCtx, "%%%")
	if _, err := signer.SignCSRContext(getCtx, csrReq); err != nil {
		t.Fatalf("GET attestation should not be enforced: %v", err)
	}
}

func TestDecodeAttestation(t *testing.T) {
	tests := []struct {
		name        string
		attestation string
		wantDevice  string
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
