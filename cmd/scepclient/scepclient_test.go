package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuildChallengeAllowsRenewalWithoutSecretWhenCertExists(t *testing.T) {
	t.Parallel()

	certPath := filepath.Join(t.TempDir(), "cert.pem")
	writeTestCertificate(t, certPath)

	challenge, err := buildChallenge("client-001", "", certPath)
	if err != nil {
		t.Fatalf("buildChallenge returned error: %v", err)
	}
	if challenge != "" {
		t.Fatalf("want empty challenge for renewal, got %q", challenge)
	}
}

func TestBuildChallengeRequiresSecretWhenCertificateIsMissing(t *testing.T) {
	t.Parallel()

	certPath := filepath.Join(t.TempDir(), "missing-cert.pem")
	_, err := buildChallenge("client-001", "", certPath)
	if err == nil {
		t.Fatal("expected missing secret to fail without an existing certificate")
	}
	if !strings.Contains(err.Error(), "please set -secret option for initial enrollment") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestInvokedAsDeviceIDProbe(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name    string
		path    string
		expects bool
	}{
		{name: "probe exe", path: `C:\Program Files\MyTunnelApp\device-id-probe.exe`, expects: true},
		{name: "probe bare", path: `device-id-probe`, expects: true},
		{name: "scepclient exe", path: `C:\Program Files\MyTunnelApp\scepclient.exe`, expects: false},
		{name: "other", path: `helper.exe`, expects: false},
	}

	for _, tc := range testCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := invokedAsDeviceIDProbe(tc.path); got != tc.expects {
				t.Fatalf("invokedAsDeviceIDProbe(%q) = %v, want %v", tc.path, got, tc.expects)
			}
		})
	}
}

func TestFormatDeviceIdentityOutputText(t *testing.T) {
	t.Parallel()

	output, err := formatDeviceIdentityOutput(&deviceIdentity{
		ExpectedDeviceID: "abc123",
		DeviceID:         "abc123",
		EKPublicB64:      "Zm9v",
	}, false)
	if err != nil {
		t.Fatalf("formatDeviceIdentityOutput returned error: %v", err)
	}
	if !strings.Contains(output, "expected_device_id: abc123\n") {
		t.Fatalf("expected human-readable output to contain expected_device_id, got %q", output)
	}
	if !strings.Contains(output, "device_id: abc123\n") {
		t.Fatalf("expected human-readable output to contain device_id, got %q", output)
	}
	if !strings.Contains(output, "ek_public_b64: Zm9v\n") {
		t.Fatalf("expected human-readable output to contain ek_public_b64, got %q", output)
	}
}

func TestFormatDeviceIdentityOutputJSON(t *testing.T) {
	t.Parallel()

	output, err := formatDeviceIdentityOutput(&deviceIdentity{
		ExpectedDeviceID: "abc123",
		DeviceID:         "abc123",
		EKPublicB64:      "Zm9v",
	}, true)
	if err != nil {
		t.Fatalf("formatDeviceIdentityOutput returned error: %v", err)
	}

	var decoded deviceIdentity
	if err := json.Unmarshal([]byte(strings.TrimSpace(output)), &decoded); err != nil {
		t.Fatalf("output was not valid JSON: %v", err)
	}
	if decoded.ExpectedDeviceID != "abc123" || decoded.DeviceID != "abc123" || decoded.EKPublicB64 != "Zm9v" {
		t.Fatalf("unexpected decoded payload: %+v", decoded)
	}
}

func writeTestCertificate(t *testing.T, path string) {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "client-001",
		},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		BasicConstraintsValid: true,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  certificatePEMBlockType,
		Bytes: certDER,
	})
	if err := os.WriteFile(path, certPEM, 0o666); err != nil {
		t.Fatalf("write certificate: %v", err)
	}
}
