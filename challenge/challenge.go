// Package challenge defines an interface for a dynamic challenge password cache.
package challenge

import (
	"context"
	"crypto/x509"
	"errors"

	"github.com/procube-open/scep/scep"
	scepserver "github.com/procube-open/scep/server"
)

// Store is a dynamic challenge password cache.
type Store interface {
	SCEPChallenge() (string, error)
	HasChallenge(pw string) (bool, error)
}

// Middleware wraps next in a CSRSigner that verifies and invalidates the challenge
func Middleware(store Store, next scepserver.CSRSignerContext) scepserver.CSRSignerContextFunc {
	return func(ctx context.Context, m *scep.CSRReqMessage) (*x509.Certificate, error) {
		// TODO: compare challenge only for PKCSReq?
		valid, err := store.HasChallenge(m.ChallengePassword)
		if err != nil {
			return nil, err
		}
		if !valid {
			return nil, errors.New("invalid challenge")
		}
		return next.SignCSRContext(ctx, m)
	}
}
