package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
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
