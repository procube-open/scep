package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"software.sslmate.com/src/go-pkcs12"
)

type keygenResult struct {
	PublicKeySPKIB64 string `json:"public_key_spki_b64"`
}

func loadCert(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("failed to decode certificate PEM from %s", path)
	}
	return x509.ParseCertificate(block.Bytes)
}

func loadKey(path string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "RSA PRIVATE KEY" {
		return nil, fmt.Errorf("failed to decode RSA private key PEM from %s", path)
	}
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}

func writeKey(path string, key *rsa.PrivateKey) error {
	block := &pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, pem.EncodeToMemory(block), 0o600)
}

func main() {
	certPath := flag.String("cert", "", "PEM certificate path")
	keyPath := flag.String("key", "", "PEM RSA private key path")
	outPath := flag.String("out", "", "output PKCS#12 path")
	password := flag.String("password", "", "PKCS#12 password")
	generateKeyOut := flag.String("generate-key-out", "", "output RSA private key PEM path")
	bits := flag.Int("bits", 2048, "RSA key size in bits")
	flag.Parse()

	if *generateKeyOut != "" {
		key, err := rsa.GenerateKey(rand.Reader, *bits)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := writeKey(*generateKeyOut, key); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		publicKeyDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := json.NewEncoder(os.Stdout).Encode(keygenResult{
			PublicKeySPKIB64: base64.RawURLEncoding.EncodeToString(publicKeyDER),
		}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if *certPath == "" || *keyPath == "" || *outPath == "" {
		fmt.Fprintln(os.Stderr, "please set -cert, -key, and -out")
		os.Exit(1)
	}

	cert, err := loadCert(*certPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	key, err := loadKey(*keyPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	pfx, err := pkcs12.LegacyDES.Encode(key, cert, nil, *password)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	if err := os.WriteFile(*outPath, pfx, 0600); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
