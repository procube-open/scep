package scepserver

import (
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/go-attestation/attest"
	"github.com/procube-open/scep/utils"
)

const defaultAttestationActivationTTL = 5 * time.Minute

type AttestationActivationService struct {
	mu      sync.Mutex
	ttl     time.Duration
	now     func() time.Time
	records map[string]attestationActivationRecord
}

type attestationActivationRecord struct {
	ClientUID string
	DeviceID  string
	Nonce     string
	Secret    []byte
	ExpiresAt time.Time
}

type AttestationActivationRequest struct {
	ClientUID               string `json:"client_uid"`
	DeviceID                string `json:"device_id"`
	Nonce                   string `json:"nonce"`
	AIKTPMPublicB64         string `json:"aik_tpm_public_b64"`
	AIKCreateDataB64        string `json:"aik_create_data_b64"`
	AIKCreateAttestationB64 string `json:"aik_create_attestation_b64"`
	AIKCreateSignatureB64   string `json:"aik_create_signature_b64"`
	UseTCSDActivationFormat bool   `json:"use_tcsd_activation_format,omitempty"`
	EKPublicB64             string `json:"ek_public_b64"`
}

type AttestationActivationResponse struct {
	ActivationID  string    `json:"activation_id"`
	CredentialB64 string    `json:"credential_b64"`
	SecretB64     string    `json:"secret_b64"`
	DeviceID      string    `json:"device_id"`
	Nonce         string    `json:"nonce"`
	ExpiresAt     time.Time `json:"expires_at"`
}

func NewAttestationActivationService(ttl time.Duration) *AttestationActivationService {
	if ttl <= 0 {
		ttl = defaultAttestationActivationTTL
	}

	return &AttestationActivationService{
		ttl:     ttl,
		now:     time.Now,
		records: make(map[string]attestationActivationRecord),
	}
}

func (s *AttestationActivationService) Issue(clientUID, deviceID, nonce string, params attest.ActivationParameters) (string, *attest.EncryptedCredential, time.Time, error) {
	if s == nil {
		return "", nil, time.Time{}, http.ErrServerClosed
	}

	clientUID = strings.TrimSpace(clientUID)
	deviceID = utils.NormalizeDeviceID(deviceID)
	nonce = strings.TrimSpace(nonce)

	rawID := make([]byte, 32)
	if _, err := rand.Read(rawID); err != nil {
		return "", nil, time.Time{}, err
	}

	secret, credential, err := params.Generate()
	if err != nil {
		return "", nil, time.Time{}, err
	}

	activationID := base64.RawURLEncoding.EncodeToString(rawID)
	expiresAt := s.now().Add(s.ttl)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.pruneExpiredLocked()
	s.records[activationID] = attestationActivationRecord{
		ClientUID: clientUID,
		DeviceID:  deviceID,
		Nonce:     nonce,
		Secret:    append([]byte(nil), secret...),
		ExpiresAt: expiresAt,
	}

	return activationID, credential, expiresAt, nil
}

func (s *AttestationActivationService) VerifyAndConsume(clientUID, deviceID, nonce, activationID string, proof []byte) bool {
	if s == nil {
		return false
	}

	clientUID = strings.TrimSpace(clientUID)
	deviceID = utils.NormalizeDeviceID(deviceID)
	nonce = strings.TrimSpace(nonce)
	activationID = strings.TrimSpace(activationID)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.pruneExpiredLocked()

	record, ok := s.records[activationID]
	if !ok {
		return false
	}
	if record.ClientUID != clientUID || record.DeviceID != deviceID || record.Nonce != nonce {
		return false
	}

	delete(s.records, activationID)
	return subtle.ConstantTimeCompare(record.Secret, proof) == 1
}

func (s *AttestationActivationService) pruneExpiredLocked() {
	now := s.now()
	for activationID, record := range s.records {
		if !record.ExpiresAt.After(now) {
			delete(s.records, activationID)
		}
	}
}

func NewAttestationActivationHandler(depot requestClientStore, nonces *AttestationNonceService, activations *AttestationActivationService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if depot == nil || nonces == nil || activations == nil {
			http.Error(w, "attestation activation service is unavailable", http.StatusInternalServerError)
			return
		}

		defer r.Body.Close()

		var req AttestationActivationRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "failed to decode request", http.StatusBadRequest)
			return
		}

		req.ClientUID = strings.TrimSpace(req.ClientUID)
		req.DeviceID = utils.NormalizeDeviceID(req.DeviceID)
		req.Nonce = strings.TrimSpace(req.Nonce)
		req.AIKTPMPublicB64 = strings.TrimSpace(req.AIKTPMPublicB64)
		req.AIKCreateDataB64 = strings.TrimSpace(req.AIKCreateDataB64)
		req.AIKCreateAttestationB64 = strings.TrimSpace(req.AIKCreateAttestationB64)
		req.AIKCreateSignatureB64 = strings.TrimSpace(req.AIKCreateSignatureB64)
		req.EKPublicB64 = strings.TrimSpace(req.EKPublicB64)

		switch {
		case req.ClientUID == "":
			http.Error(w, "client_uid is required", http.StatusBadRequest)
			return
		case req.DeviceID == "":
			http.Error(w, "device_id is required", http.StatusBadRequest)
			return
		case req.Nonce == "":
			http.Error(w, "nonce is required", http.StatusBadRequest)
			return
		case req.AIKTPMPublicB64 == "":
			http.Error(w, "aik_tpm_public_b64 is required", http.StatusBadRequest)
			return
		case req.AIKCreateDataB64 == "":
			http.Error(w, "aik_create_data_b64 is required", http.StatusBadRequest)
			return
		case req.AIKCreateAttestationB64 == "":
			http.Error(w, "aik_create_attestation_b64 is required", http.StatusBadRequest)
			return
		case req.AIKCreateSignatureB64 == "":
			http.Error(w, "aik_create_signature_b64 is required", http.StatusBadRequest)
			return
		case req.EKPublicB64 == "":
			http.Error(w, "ek_public_b64 is required", http.StatusBadRequest)
			return
		}

		client, err := depot.GetClient(req.ClientUID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if client == nil {
			http.Error(w, "client not found", http.StatusNotFound)
			return
		}

		registeredDeviceID, err := validateClientDeviceIDBinding(client.Attributes, req.DeviceID, req.EKPublicB64)
		if err != nil {
			switch err {
			case errRegisteredDeviceIDMissing:
				http.Error(w, err.Error(), http.StatusBadRequest)
			case errRequestDeviceIDMismatch:
				http.Error(w, err.Error(), http.StatusForbidden)
			case errEKPublicRequired, errEKPublicInvalid:
				http.Error(w, err.Error(), http.StatusBadRequest)
			default:
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
		if !nonces.Has(req.ClientUID, registeredDeviceID, req.Nonce) {
			http.Error(w, "nonce mismatch", http.StatusForbidden)
			return
		}

		akPublic, err := decodeBase64URL(req.AIKTPMPublicB64)
		if err != nil || len(akPublic) == 0 {
			http.Error(w, "aik_tpm_public_b64 is not valid base64url", http.StatusBadRequest)
			return
		}
		createData, err := decodeBase64URL(req.AIKCreateDataB64)
		if err != nil || len(createData) == 0 {
			http.Error(w, "aik_create_data_b64 is not valid base64url", http.StatusBadRequest)
			return
		}
		createAttestation, err := decodeBase64URL(req.AIKCreateAttestationB64)
		if err != nil || len(createAttestation) == 0 {
			http.Error(w, "aik_create_attestation_b64 is not valid base64url", http.StatusBadRequest)
			return
		}
		createSignature, err := decodeBase64URL(req.AIKCreateSignatureB64)
		if err != nil || len(createSignature) == 0 {
			http.Error(w, "aik_create_signature_b64 is not valid base64url", http.StatusBadRequest)
			return
		}
		ekPublicDER, err := decodeBase64URL(req.EKPublicB64)
		if err != nil || len(ekPublicDER) == 0 {
			http.Error(w, "ek_public_b64 is not valid base64url", http.StatusBadRequest)
			return
		}
		ekPublic, err := x509.ParsePKIXPublicKey(ekPublicDER)
		if err != nil {
			http.Error(w, "ek_public_b64 is not a valid SubjectPublicKeyInfo", http.StatusBadRequest)
			return
		}

		activationID, credential, expiresAt, err := activations.Issue(
			req.ClientUID,
			registeredDeviceID,
			req.Nonce,
			attest.ActivationParameters{
				EK: ekPublic,
				AK: attest.AttestationParameters{
					Public:                  akPublic,
					UseTCSDActivationFormat: req.UseTCSDActivationFormat,
					CreateData:              createData,
					CreateAttestation:       createAttestation,
					CreateSignature:         createSignature,
				},
			},
		)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(AttestationActivationResponse{
			ActivationID:  activationID,
			CredentialB64: base64.RawURLEncoding.EncodeToString(credential.Credential),
			SecretB64:     base64.RawURLEncoding.EncodeToString(credential.Secret),
			DeviceID:      registeredDeviceID,
			Nonce:         req.Nonce,
			ExpiresAt:     expiresAt.UTC(),
		}); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}
