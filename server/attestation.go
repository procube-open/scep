package scepserver

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/procube-open/scep/depot/mysql"
)

var (
	ErrMissingAttestation = errors.New("missing attestation")
	ErrInvalidAttestation = errors.New("invalid attestation")
)

type attestationContextKey struct{}

func ContextWithAttestation(ctx context.Context, attestation string) context.Context {
	return context.WithValue(ctx, attestationContextKey{}, attestation)
}

func AttestationFromContext(ctx context.Context) (string, bool) {
	attestation, ok := ctx.Value(attestationContextKey{}).(string)
	if !ok {
		return "", false
	}
	return attestation, attestation != ""
}

type requestMethodContextKey struct{}

func ContextWithRequestMethod(ctx context.Context, method string) context.Context {
	return context.WithValue(ctx, requestMethodContextKey{}, method)
}

func RequestMethodFromContext(ctx context.Context) (string, bool) {
	method, ok := ctx.Value(requestMethodContextKey{}).(string)
	if !ok {
		return "", false
	}
	return method, method != ""
}

type challengePasswordContextKey struct{}

func ContextWithChallengePassword(ctx context.Context, challenge string) context.Context {
	return context.WithValue(ctx, challengePasswordContextKey{}, challenge)
}

func ChallengePasswordFromContext(ctx context.Context) (string, bool) {
	challenge, ok := ctx.Value(challengePasswordContextKey{}).(string)
	if !ok {
		return "", false
	}
	return challenge, challenge != ""
}

type AttestationVerifier interface {
	VerifyAttestation(context.Context, string) error
}

type AttestationVerifierFunc func(context.Context, string) error

func (f AttestationVerifierFunc) VerifyAttestation(ctx context.Context, attestation string) error {
	return f(ctx, attestation)
}

func Base64URLJSONAttestationVerifier() AttestationVerifierFunc {
	return func(_ context.Context, attestation string) error {
		_, err := decodeAttestation(attestation)
		return err
	}
}

func MySQLDeviceIDAttestationVerifier(depot *mysql.MySQLDepot) AttestationVerifierFunc {
	return func(ctx context.Context, attestation string) error {
		if depot == nil {
			return errors.New("attestation depot is nil")
		}

		claims, err := decodeAttestation(attestation)
		if err != nil {
			return err
		}

		challenge, ok := ChallengePasswordFromContext(ctx)
		if !ok {
			return errors.New("invalid challenge")
		}
		arr := strings.Split(challenge, "\\")
		if len(arr) != 2 {
			return errors.New("invalid challenge")
		}

		client, err := depot.GetClient(arr[0])
		if err != nil {
			return err
		}
		if client == nil {
			return errors.New("invalid challenge")
		}

		registeredDeviceID, ok := lookupDeviceID(client.Attributes)
		if !ok {
			return fmt.Errorf("%w: registered device_id is missing", ErrInvalidAttestation)
		}
		if claims.DeviceID != registeredDeviceID {
			return fmt.Errorf("%w: device_id mismatch", ErrInvalidAttestation)
		}

		return nil
	}
}

type attestationClaims struct {
	DeviceID string `json:"device_id"`
}

func decodeAttestation(attestation string) (*attestationClaims, error) {
	if attestation == "" {
		return nil, ErrMissingAttestation
	}

	payload, err := decodeBase64URL(attestation)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidAttestation, err)
	}

	var claims attestationClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("%w: decoded payload is not valid json", ErrInvalidAttestation)
	}
	claims.DeviceID = strings.TrimSpace(claims.DeviceID)
	if claims.DeviceID == "" {
		return nil, fmt.Errorf("%w: missing device_id", ErrInvalidAttestation)
	}
	return &claims, nil
}

func lookupDeviceID(attributes map[string]interface{}) (string, bool) {
	if attributes == nil {
		return "", false
	}

	deviceID, ok := attributes["device_id"].(string)
	if !ok {
		return "", false
	}
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return "", false
	}

	return deviceID, true
}

func decodeBase64URL(payload string) ([]byte, error) {
	if decoded, err := base64.RawURLEncoding.DecodeString(payload); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(payload)
}
