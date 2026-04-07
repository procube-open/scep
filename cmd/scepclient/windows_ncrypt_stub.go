//go:build !windows

package main

import (
	"crypto"
	"errors"
	"io"
)

type windowsNCryptKey struct{}

func openWindowsNCryptKey(providerName, keyName, publicKeySPKI string) (*windowsNCryptKey, error) {
	return nil, errors.New("windows persisted keys are only supported on Windows")
}

func (k *windowsNCryptKey) Close() error { return nil }

func (k *windowsNCryptKey) Public() crypto.PublicKey { return nil }

func (k *windowsNCryptKey) Sign(_ io.Reader, _ []byte, _ crypto.SignerOpts) ([]byte, error) {
	return nil, errors.New("windows persisted keys are only supported on Windows")
}

func (k *windowsNCryptKey) Decrypt(_ io.Reader, _ []byte, _ crypto.DecrypterOpts) ([]byte, error) {
	return nil, errors.New("windows persisted keys are only supported on Windows")
}
