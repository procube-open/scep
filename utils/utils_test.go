package utils

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"testing"
)

func TestNormalizeDeviceID(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "trim and lowercase",
			raw:  "  DEVICE-01  ",
			want: "device-01",
		},
		{
			name: "empty stays empty",
			raw:  "   ",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizeDeviceID(tt.raw); got != tt.want {
				t.Fatalf("want %q, got %q", tt.want, got)
			}
		})
	}
}

func TestNormalizeSHA256Fingerprint(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "trim lowercase and strip separators",
			raw:  " AA:BB-CCdd ",
			want: "",
		},
		{
			name: "valid fingerprint with separators",
			raw:  "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
			want: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
		},
		{
			name: "invalid hex returns empty",
			raw:  "zz",
			want: "",
		},
		{
			name: "empty stays empty",
			raw:  " ",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizeSHA256Fingerprint(tt.raw); got != tt.want {
				t.Fatalf("want %q, got %q", tt.want, got)
			}
		})
	}
}

func TestCanonicalDeviceIDFromPKIXPublicKeyDER(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(key.Public())
	if err != nil {
		t.Fatal(err)
	}

	got, err := CanonicalDeviceIDFromPKIXPublicKeyDER(der)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	sum := sha256.Sum256(der)
	want := fmt.Sprintf("%x", sum[:])
	if got != want {
		t.Fatalf("want %q, got %q", want, got)
	}
}

func TestCanonicalDeviceIDFromBase64URLPKIXPublicKey(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(key.Public())
	if err != nil {
		t.Fatal(err)
	}

	got, err := CanonicalDeviceIDFromBase64URLPKIXPublicKey(base64.RawURLEncoding.EncodeToString(der))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	sum := sha256.Sum256(der)
	want := fmt.Sprintf("%x", sum[:])
	if got != want {
		t.Fatalf("want %q, got %q", want, got)
	}
}
