//go:build windows

package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	ncryptDLL                     = windows.NewLazySystemDLL("ncrypt.dll")
	procNCryptOpenStorageProvider = ncryptDLL.NewProc("NCryptOpenStorageProvider")
	procNCryptOpenKey             = ncryptDLL.NewProc("NCryptOpenKey")
	procNCryptExportKey           = ncryptDLL.NewProc("NCryptExportKey")
	procNCryptDeleteKey           = ncryptDLL.NewProc("NCryptDeleteKey")
	procNCryptSignHash            = ncryptDLL.NewProc("NCryptSignHash")
	procNCryptDecrypt             = ncryptDLL.NewProc("NCryptDecrypt")
	procNCryptFreeObject          = ncryptDLL.NewProc("NCryptFreeObject")
)

const (
	ncryptMachineKeyFlag = 0x20
	ncryptPadPKCS1Flag   = 0x2
	ncryptPadOAEPFlag    = 0x4
	bcryptRSAPublicMagic = 0x31415352
)

type bcryptPkcs1PaddingInfo struct {
	pszAlgID *uint16
}

type bcryptOaepPaddingInfo struct {
	pszAlgID *uint16
	pbLabel  *byte
	cbLabel  uint32
}

type windowsNCryptKey struct {
	providerHandle uintptr
	keyHandle      uintptr
	publicKey      *rsa.PublicKey
	publicKeySPKI  string
}

func openWindowsNCryptKey(providerName, keyName, publicKeySPKI string) (*windowsNCryptKey, error) {
	providerNamePtr, err := windows.UTF16PtrFromString(providerName)
	if err != nil {
		return nil, err
	}
	keyNamePtr, err := windows.UTF16PtrFromString(keyName)
	if err != nil {
		return nil, err
	}

	var providerHandle uintptr
	status, _, _ := procNCryptOpenStorageProvider.Call(
		uintptr(unsafe.Pointer(&providerHandle)),
		uintptr(unsafe.Pointer(providerNamePtr)),
		0,
	)
	if status != 0 {
		return nil, fmt.Errorf("NCryptOpenStorageProvider(%q) failed: 0x%x", providerName, uint32(status))
	}

	var keyHandle uintptr
	status, _, _ = procNCryptOpenKey.Call(
		providerHandle,
		uintptr(unsafe.Pointer(&keyHandle)),
		uintptr(unsafe.Pointer(keyNamePtr)),
		0,
		ncryptMachineKeyFlag,
	)
	if status != 0 {
		_, _, _ = procNCryptFreeObject.Call(providerHandle)
		return nil, fmt.Errorf("NCryptOpenKey(%q) failed: 0x%x", keyName, uint32(status))
	}

	publicKey, resolvedPublicKeySPKI, err := loadWindowsNCryptRSAPublicKey(keyHandle, publicKeySPKI)
	if err != nil {
		_, _, _ = procNCryptFreeObject.Call(keyHandle)
		_, _, _ = procNCryptFreeObject.Call(providerHandle)
		return nil, err
	}

	return &windowsNCryptKey{
		providerHandle: providerHandle,
		keyHandle:      keyHandle,
		publicKey:      publicKey,
		publicKeySPKI:  resolvedPublicKeySPKI,
	}, nil
}

func loadWindowsNCryptRSAPublicKey(keyHandle uintptr, publicKeySPKI string) (*rsa.PublicKey, string, error) {
	publicKeySPKI = strings.TrimSpace(publicKeySPKI)
	if publicKeySPKI == "" {
		derivedSPKI, err := exportWindowsNCryptPublicKeySPKI(keyHandle)
		if err != nil {
			return nil, "", err
		}
		publicKeySPKI = derivedSPKI
	}

	publicKeyDER, err := base64.RawURLEncoding.DecodeString(publicKeySPKI)
	if err != nil {
		return nil, "", fmt.Errorf("decode public key spki: %w", err)
	}
	publicKeyAny, err := x509.ParsePKIXPublicKey(publicKeyDER)
	if err != nil {
		return nil, "", fmt.Errorf("parse public key spki: %w", err)
	}
	publicKey, ok := publicKeyAny.(*rsa.PublicKey)
	if !ok {
		return nil, "", fmt.Errorf("public key is %T, want *rsa.PublicKey", publicKeyAny)
	}
	return publicKey, publicKeySPKI, nil
}

func exportWindowsNCryptPublicKeySPKI(keyHandle uintptr) (string, error) {
	blobType, err := windows.UTF16PtrFromString("RSAPUBLICBLOB")
	if err != nil {
		return "", err
	}

	var size uint32
	status, _, _ := procNCryptExportKey.Call(
		keyHandle,
		0,
		uintptr(unsafe.Pointer(blobType)),
		0,
		0,
		0,
		uintptr(unsafe.Pointer(&size)),
		0,
	)
	if status != 0 {
		return "", fmt.Errorf("NCryptExportKey(size) failed: 0x%x", uint32(status))
	}

	blob := make([]byte, size)
	status, _, _ = procNCryptExportKey.Call(
		keyHandle,
		0,
		uintptr(unsafe.Pointer(blobType)),
		0,
		uintptr(unsafe.Pointer(unsafe.SliceData(blob))),
		uintptr(len(blob)),
		uintptr(unsafe.Pointer(&size)),
		0,
	)
	if status != 0 {
		return "", fmt.Errorf("NCryptExportKey failed: 0x%x", uint32(status))
	}

	publicKey, err := parseWindowsRSAPublicBlob(blob[:size])
	if err != nil {
		return "", err
	}
	spkiDER, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return "", fmt.Errorf("marshal public key spki: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(spkiDER), nil
}

func parseWindowsRSAPublicBlob(blob []byte) (*rsa.PublicKey, error) {
	const headerSize = 24
	if len(blob) < headerSize {
		return nil, fmt.Errorf("RSA public key blob was shorter than the header")
	}
	if binary.LittleEndian.Uint32(blob[0:4]) != bcryptRSAPublicMagic {
		return nil, fmt.Errorf("RSA public key blob had unexpected magic 0x%x", binary.LittleEndian.Uint32(blob[0:4]))
	}

	exponentLen := int(binary.LittleEndian.Uint32(blob[8:12]))
	modulusLen := int(binary.LittleEndian.Uint32(blob[12:16]))
	exponentOffset := headerSize
	modulusOffset := exponentOffset + exponentLen
	modulusEnd := modulusOffset + modulusLen
	if exponentLen <= 0 || modulusLen <= 0 || modulusEnd > len(blob) {
		return nil, fmt.Errorf("RSA public key blob was truncated")
	}

	exponentBytes := blob[exponentOffset:modulusOffset]
	modulusBytes := blob[modulusOffset:modulusEnd]

	exponent := 0
	for _, b := range exponentBytes {
		exponent = (exponent << 8) | int(b)
	}
	if exponent <= 0 {
		return nil, fmt.Errorf("RSA public key blob had invalid exponent")
	}

	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(modulusBytes),
		E: exponent,
	}, nil
}

func (k *windowsNCryptKey) Close() error {
	if k.keyHandle != 0 {
		_, _, _ = procNCryptFreeObject.Call(k.keyHandle)
		k.keyHandle = 0
	}
	if k.providerHandle != 0 {
		_, _, _ = procNCryptFreeObject.Call(k.providerHandle)
		k.providerHandle = 0
	}
	return nil
}

func (k *windowsNCryptKey) Public() crypto.PublicKey {
	return k.publicKey
}

func (k *windowsNCryptKey) Sign(_ io.Reader, digest []byte, opts crypto.SignerOpts) ([]byte, error) {
	hashNamePtr, err := windows.UTF16PtrFromString(hashAlgorithmName(opts.HashFunc()))
	if err != nil {
		return nil, err
	}
	paddingInfo := bcryptPkcs1PaddingInfo{pszAlgID: hashNamePtr}
	var size uint32
	status, _, _ := procNCryptSignHash.Call(
		k.keyHandle,
		uintptr(unsafe.Pointer(&paddingInfo)),
		uintptr(unsafe.Pointer(unsafe.SliceData(digest))),
		uintptr(len(digest)),
		0,
		0,
		uintptr(unsafe.Pointer(&size)),
		ncryptPadPKCS1Flag,
	)
	if status != 0 {
		return nil, fmt.Errorf("NCryptSignHash(size) failed: 0x%x", uint32(status))
	}
	signature := make([]byte, size)
	status, _, _ = procNCryptSignHash.Call(
		k.keyHandle,
		uintptr(unsafe.Pointer(&paddingInfo)),
		uintptr(unsafe.Pointer(unsafe.SliceData(digest))),
		uintptr(len(digest)),
		uintptr(unsafe.Pointer(unsafe.SliceData(signature))),
		uintptr(len(signature)),
		uintptr(unsafe.Pointer(&size)),
		ncryptPadPKCS1Flag,
	)
	if status != 0 {
		return nil, fmt.Errorf("NCryptSignHash failed: 0x%x", uint32(status))
	}
	return signature[:size], nil
}

func (k *windowsNCryptKey) Decrypt(_ io.Reader, ciphertext []byte, opts crypto.DecrypterOpts) ([]byte, error) {
	flags := uintptr(ncryptPadPKCS1Flag)
	var paddingInfo unsafe.Pointer
	var oaep bcryptOaepPaddingInfo

	switch typed := opts.(type) {
	case *rsa.OAEPOptions:
		hashNamePtr, err := windows.UTF16PtrFromString(hashAlgorithmName(typed.Hash))
		if err != nil {
			return nil, err
		}
		oaep = bcryptOaepPaddingInfo{pszAlgID: hashNamePtr}
		paddingInfo = unsafe.Pointer(&oaep)
		flags = ncryptPadOAEPFlag
	case *rsa.PKCS1v15DecryptOptions, nil:
		paddingInfo = nil
	default:
		return nil, fmt.Errorf("unsupported decrypt opts %T", opts)
	}

	var size uint32
	status, _, _ := procNCryptDecrypt.Call(
		k.keyHandle,
		uintptr(unsafe.Pointer(unsafe.SliceData(ciphertext))),
		uintptr(len(ciphertext)),
		uintptr(paddingInfo),
		0,
		0,
		uintptr(unsafe.Pointer(&size)),
		flags,
	)
	if status != 0 {
		return nil, fmt.Errorf("NCryptDecrypt(size) failed: 0x%x", uint32(status))
	}
	plaintext := make([]byte, size)
	status, _, _ = procNCryptDecrypt.Call(
		k.keyHandle,
		uintptr(unsafe.Pointer(unsafe.SliceData(ciphertext))),
		uintptr(len(ciphertext)),
		uintptr(paddingInfo),
		uintptr(unsafe.Pointer(unsafe.SliceData(plaintext))),
		uintptr(len(plaintext)),
		uintptr(unsafe.Pointer(&size)),
		flags,
	)
	if status != 0 {
		return nil, fmt.Errorf("NCryptDecrypt failed: 0x%x", uint32(status))
	}
	return plaintext[:size], nil
}

func hashAlgorithmName(hash crypto.Hash) string {
	switch hash {
	case crypto.SHA1:
		return "SHA1"
	case crypto.SHA224:
		return "SHA224"
	case crypto.SHA256:
		return "SHA256"
	case crypto.SHA384:
		return "SHA384"
	case crypto.SHA512:
		return "SHA512"
	default:
		return "SHA256"
	}
}
