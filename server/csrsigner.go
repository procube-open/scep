package scepserver

import (
	"context"
	"crypto/subtle"
	"crypto/x509"
	"errors"
	"strings"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/scep"
)

// CSRSignerContext is a handler for signing CSRs by a CA/RA.
//
// SignCSRContext should take the CSR in the CSRReqMessage and return a
// Certificate signed by the CA.
type CSRSignerContext interface {
	SignCSRContext(context.Context, *scep.CSRReqMessage) (*x509.Certificate, error)
}

// CSRSignerContextFunc is an adapter for CSR signing by the CA/RA.
type CSRSignerContextFunc func(context.Context, *scep.CSRReqMessage) (*x509.Certificate, error)

// SignCSR calls f(ctx, m).
func (f CSRSignerContextFunc) SignCSRContext(ctx context.Context, m *scep.CSRReqMessage) (*x509.Certificate, error) {
	return f(ctx, m)
}

// CSRSigner is a handler for CSR signing by the CA/RA
//
// SignCSR should take the CSR in the CSRReqMessage and return a
// Certificate signed by the CA.
type CSRSigner interface {
	SignCSR(*scep.CSRReqMessage) (*x509.Certificate, error)
}

// CSRSignerFunc is an adapter for CSR signing by the CA/RA.
type CSRSignerFunc func(*scep.CSRReqMessage) (*x509.Certificate, error)

// SignCSR calls f(m).
func (f CSRSignerFunc) SignCSR(m *scep.CSRReqMessage) (*x509.Certificate, error) {
	return f(m)
}

// NopCSRSigner does nothing.
func NopCSRSigner() CSRSignerContextFunc {
	return func(_ context.Context, _ *scep.CSRReqMessage) (*x509.Certificate, error) {
		return nil, nil
	}
}

// StaticChallengeMiddleware wraps next and validates the challenge from the CSR.
func StaticChallengeMiddleware(challenge string, next CSRSignerContext) CSRSignerContextFunc {
	challengeBytes := []byte(challenge)
	return func(ctx context.Context, m *scep.CSRReqMessage) (*x509.Certificate, error) {
		// TODO: compare challenge only for PKCSReq?
		if subtle.ConstantTimeCompare(challengeBytes, []byte(m.ChallengePassword)) != 1 {
			return nil, errors.New("invalid challenge")
		}
		return next.SignCSRContext(ctx, m)
	}
}

// IDMChallengeMiddleware
func MySQLChallengeMiddleWare(depot *mysql.MySQLDepot, next CSRSignerContext) CSRSignerContextFunc {
	return func(ctx context.Context, m *scep.CSRReqMessage) (*x509.Certificate, error) {
		arr := strings.Split(m.ChallengePassword, "\\")
		if len(arr) != 2 {
			return nil, errors.New("invalid challenge")
		}
		client, err := depot.GetClient(arr[0])
		if err != nil {
			return nil, err
		}
		if !(client.Status == "ISSUABLE" || client.Status == "UPDATABLE") {
			return nil, errors.New("client is not issuable or updatable")
		}
		secret, err := depot.GetSecret(arr[0])
		if err != nil {
			return nil, err
		}
		if secret.Secret != arr[1] {
			return nil, errors.New("invalid secret")
		}
		return next.SignCSRContext(ctx, m)
	}
}

// SignCSRAdapter adapts a next (i.e. no context) to a context signer.
func SignCSRAdapter(next CSRSigner) CSRSignerContextFunc {
	return func(_ context.Context, m *scep.CSRReqMessage) (*x509.Certificate, error) {
		return next.SignCSR(m)
	}
}
