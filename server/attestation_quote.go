package scepserver

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
)

const (
	canonicalWindowsTPMAttestationFormat = "tpm2-windows-v1"

	tpmGeneratedValue = 0xff544347
	tpmSTAttestQuote  = 0x8018

	tpmAlgSHA1   = 0x0004
	tpmAlgSHA256 = 0x000B
	tpmAlgSHA384 = 0x000C
	tpmAlgSHA512 = 0x000D

	tpmAlgRSASSA = 0x0014
	tpmAlgRSAPSS = 0x0016
	tpmAlgECDSA  = 0x0018
)

type parsedTPMQuote struct {
	signedBytes []byte
	extraData   []byte
}

type parsedTPMSignature struct {
	algorithm uint16
	hashAlg   uint16
	signature []byte
	r         *big.Int
	s         *big.Int
}

type expectedTPMQuoteExtraDataValues struct {
	raw       []byte
	compact   []byte
	keyDigest []byte
	nonce     []byte
}

// Phase 2 uses raw TPM2B_ATTEST / TPMT_SIGNATURE blobs encoded with base64url.
func verifyTPMQuoteAttestation(claims *attestationClaims) error {
	if claims == nil {
		return nil
	}
	if err := validateTPMAttestationFormat(claims.Attestation); err != nil {
		return err
	}
	if !requiresTPMQuoteVerification(claims.Attestation) {
		return nil
	}

	if claims.Attestation.AIKPublicB64 == "" || claims.Attestation.QuoteB64 == "" || claims.Attestation.QuoteSignatureB64 == "" {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}

	aikPublicDER, err := decodeBase64URL(claims.Attestation.AIKPublicB64)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	aikPublicKey, err := x509.ParsePKIXPublicKey(aikPublicDER)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}

	quoteBlob, err := decodeBase64URL(claims.Attestation.QuoteB64)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	quote, err := parseTPMQuote(quoteBlob)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	expectedExtraData, err := expectedTPMQuoteExtraData(claims)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	if err := verifyExpectedTPMQuoteExtraData(quote.extraData, expectedExtraData); err != nil {
		return err
	}

	signatureBlob, err := decodeBase64URL(claims.Attestation.QuoteSignatureB64)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	signature, err := parseTPMSignature(signatureBlob)
	if err != nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	if err := verifyTPMSignature(aikPublicKey, quote.signedBytes, signature); err != nil {
		return fmt.Errorf("%w: invalid_quote_signature", ErrInvalidAttestation)
	}

	return nil
}

func requiresTPMQuoteVerification(bundle attestationBundle) bool {
	return bundle.Format == canonicalWindowsTPMAttestationFormat
}

func validateTPMAttestationFormat(bundle attestationBundle) error {
	if bundle.Format == canonicalWindowsTPMAttestationFormat {
		return nil
	}
	return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
}

func hasTPMQuoteFields(bundle attestationBundle) bool {
	return bundle.AIKPublicB64 != "" || bundle.QuoteB64 != "" || bundle.QuoteSignatureB64 != ""
}

func expectedTPMQuoteExtraData(claims *attestationClaims) (*expectedTPMQuoteExtraDataValues, error) {
	if claims == nil {
		return nil, fmt.Errorf("missing claims")
	}

	nonceBytes, err := decodeBase64URL(claims.Attestation.Nonce)
	if err != nil || len(nonceBytes) == 0 {
		return nil, fmt.Errorf("invalid attestation nonce")
	}

	publicKeyBytes, err := decodeBase64URL(claims.Key.PublicKeySPKIB64)
	if err != nil || len(publicKeyBytes) == 0 {
		return nil, fmt.Errorf("invalid attested public key")
	}
	if _, err := x509.ParsePKIXPublicKey(publicKeyBytes); err != nil {
		return nil, err
	}

	keyDigest := sha256.Sum256(publicKeyBytes)
	raw := append(append([]byte(nil), keyDigest[:]...), nonceBytes...)
	compact := sha256.Sum256(raw)
	return &expectedTPMQuoteExtraDataValues{
		raw:       raw,
		compact:   compact[:],
		keyDigest: keyDigest[:],
		nonce:     append([]byte(nil), nonceBytes...),
	}, nil
}

func verifyExpectedTPMQuoteExtraData(extraData []byte, expected *expectedTPMQuoteExtraDataValues) error {
	if expected == nil {
		return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
	}
	if bytes.Equal(extraData, expected.raw) || bytes.Equal(extraData, expected.compact) {
		return nil
	}
	if len(extraData) == len(expected.raw) {
		if !bytes.Equal(extraData[:len(expected.keyDigest)], expected.keyDigest) {
			return fmt.Errorf("%w: public_key_mismatch", ErrInvalidAttestation)
		}
		if !bytes.Equal(extraData[len(expected.keyDigest):], expected.nonce) {
			return fmt.Errorf("%w: nonce_mismatch", ErrInvalidAttestation)
		}
	}
	return fmt.Errorf("%w: invalid_attestation_format", ErrInvalidAttestation)
}

func parseTPMQuote(blob []byte) (*parsedTPMQuote, error) {
	signedBytes, err := normalizeTPM2BAttest(blob)
	if err != nil {
		return nil, err
	}

	reader := bytes.NewReader(signedBytes)

	magic, err := readUint32(reader)
	if err != nil {
		return nil, err
	}
	if magic != tpmGeneratedValue {
		return nil, fmt.Errorf("unexpected TPM_GENERATED value: 0x%x", magic)
	}

	typ, err := readUint16(reader)
	if err != nil {
		return nil, err
	}
	if typ != tpmSTAttestQuote {
		return nil, fmt.Errorf("unexpected attestation type: 0x%x", typ)
	}

	if _, err := readTPM2B(reader); err != nil {
		return nil, err
	}
	extraData, err := readTPM2B(reader)
	if err != nil {
		return nil, err
	}
	if err := skipQuoteClockInfo(reader); err != nil {
		return nil, err
	}
	if _, err := readUint64(reader); err != nil {
		return nil, err
	}
	if err := skipTPMSQuoteInfo(reader); err != nil {
		return nil, err
	}
	if reader.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing quote data")
	}

	return &parsedTPMQuote{
		signedBytes: signedBytes,
		extraData:   extraData,
	}, nil
}

func normalizeTPM2BAttest(blob []byte) ([]byte, error) {
	if len(blob) == 0 {
		return nil, fmt.Errorf("empty quote")
	}
	if len(blob) >= 2 {
		size := int(binary.BigEndian.Uint16(blob[:2]))
		if size == len(blob)-2 {
			return append([]byte(nil), blob[2:]...), nil
		}
	}
	return append([]byte(nil), blob...), nil
}

func parseTPMSignature(blob []byte) (*parsedTPMSignature, error) {
	reader := bytes.NewReader(blob)

	algorithm, err := readUint16(reader)
	if err != nil {
		return nil, err
	}
	hashAlg, err := readUint16(reader)
	if err != nil {
		return nil, err
	}

	signature := &parsedTPMSignature{
		algorithm: algorithm,
		hashAlg:   hashAlg,
	}

	switch algorithm {
	case tpmAlgRSASSA, tpmAlgRSAPSS:
		signature.signature, err = readTPM2B(reader)
	case tpmAlgECDSA:
		var rBytes, sBytes []byte
		rBytes, err = readTPM2B(reader)
		if err == nil {
			sBytes, err = readTPM2B(reader)
		}
		if err == nil {
			signature.r = new(big.Int).SetBytes(rBytes)
			signature.s = new(big.Int).SetBytes(sBytes)
		}
	default:
		return nil, fmt.Errorf("unsupported TPM signature algorithm: 0x%x", algorithm)
	}
	if err != nil {
		return nil, err
	}
	if reader.Len() != 0 {
		return nil, fmt.Errorf("unexpected trailing signature data")
	}

	return signature, nil
}

func verifyTPMSignature(publicKey interface{}, message []byte, signature *parsedTPMSignature) error {
	if signature == nil {
		return fmt.Errorf("missing signature")
	}

	hash, digest, err := hashTPMMessage(signature.hashAlg, message)
	if err != nil {
		return err
	}

	switch signature.algorithm {
	case tpmAlgRSASSA:
		rsaPublicKey, ok := publicKey.(*rsa.PublicKey)
		if !ok {
			return fmt.Errorf("AIK public key is not RSA")
		}
		return rsa.VerifyPKCS1v15(rsaPublicKey, hash, digest, signature.signature)
	case tpmAlgRSAPSS:
		rsaPublicKey, ok := publicKey.(*rsa.PublicKey)
		if !ok {
			return fmt.Errorf("AIK public key is not RSA")
		}
		return rsa.VerifyPSS(rsaPublicKey, hash, digest, signature.signature, &rsa.PSSOptions{
			Hash:       hash,
			SaltLength: rsa.PSSSaltLengthEqualsHash,
		})
	case tpmAlgECDSA:
		ecdsaPublicKey, ok := publicKey.(*ecdsa.PublicKey)
		if !ok {
			return fmt.Errorf("AIK public key is not ECDSA")
		}
		if signature.r == nil || signature.s == nil || !ecdsa.Verify(ecdsaPublicKey, digest, signature.r, signature.s) {
			return fmt.Errorf("ECDSA signature verification failed")
		}
		return nil
	default:
		return fmt.Errorf("unsupported TPM signature algorithm: 0x%x", signature.algorithm)
	}
}

func hashTPMMessage(algorithm uint16, message []byte) (crypto.Hash, []byte, error) {
	switch algorithm {
	case tpmAlgSHA1:
		sum := sha1.Sum(message)
		return crypto.SHA1, sum[:], nil
	case tpmAlgSHA256:
		sum := sha256.Sum256(message)
		return crypto.SHA256, sum[:], nil
	case tpmAlgSHA384:
		sum := sha512.Sum384(message)
		return crypto.SHA384, sum[:], nil
	case tpmAlgSHA512:
		sum := sha512.Sum512(message)
		return crypto.SHA512, sum[:], nil
	default:
		return 0, nil, fmt.Errorf("unsupported TPM hash algorithm: 0x%x", algorithm)
	}
}

func skipQuoteClockInfo(reader *bytes.Reader) error {
	if _, err := readUint64(reader); err != nil {
		return err
	}
	if _, err := readUint32(reader); err != nil {
		return err
	}
	if _, err := readUint32(reader); err != nil {
		return err
	}
	_, err := reader.ReadByte()
	return err
}

func skipTPMSQuoteInfo(reader *bytes.Reader) error {
	count, err := readUint32(reader)
	if err != nil {
		return err
	}

	for i := uint32(0); i < count; i++ {
		if _, err := readUint16(reader); err != nil {
			return err
		}
		size, err := reader.ReadByte()
		if err != nil {
			return err
		}
		if _, err := io.CopyN(io.Discard, reader, int64(size)); err != nil {
			return err
		}
	}

	_, err = readTPM2B(reader)
	return err
}

func readTPM2B(reader *bytes.Reader) ([]byte, error) {
	size, err := readUint16(reader)
	if err != nil {
		return nil, err
	}

	value := make([]byte, size)
	if _, err := io.ReadFull(reader, value); err != nil {
		return nil, err
	}
	return value, nil
}

func readUint16(reader *bytes.Reader) (uint16, error) {
	var value uint16
	if err := binary.Read(reader, binary.BigEndian, &value); err != nil {
		return 0, err
	}
	return value, nil
}

func readUint32(reader *bytes.Reader) (uint32, error) {
	var value uint32
	if err := binary.Read(reader, binary.BigEndian, &value); err != nil {
		return 0, err
	}
	return value, nil
}

func readUint64(reader *bytes.Reader) (uint64, error) {
	var value uint64
	if err := binary.Read(reader, binary.BigEndian, &value); err != nil {
		return 0, err
	}
	return value, nil
}
