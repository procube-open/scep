package scepserver

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/procube-open/scep/utils"
)

const defaultAttestationNonceTTL = 5 * time.Minute

type AttestationNonceService struct {
	mu      sync.Mutex
	ttl     time.Duration
	now     func() time.Time
	records map[string]attestationNonceRecord
}

type attestationNonceRecord struct {
	ClientUID string
	DeviceID  string
	ExpiresAt time.Time
}

type AttestationNonceRequest struct {
	ClientUID   string `json:"client_uid"`
	DeviceID    string `json:"device_id"`
	EKPublicB64 string `json:"ek_public_b64"`
}

type AttestationNonceResponse struct {
	Nonce     string    `json:"nonce"`
	DeviceID  string    `json:"device_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

func NewAttestationNonceService(ttl time.Duration) *AttestationNonceService {
	if ttl <= 0 {
		ttl = defaultAttestationNonceTTL
	}

	return &AttestationNonceService{
		ttl:     ttl,
		now:     time.Now,
		records: make(map[string]attestationNonceRecord),
	}
}

func (s *AttestationNonceService) Issue(clientUID, deviceID string) (string, time.Time, error) {
	if s == nil {
		return "", time.Time{}, http.ErrServerClosed
	}

	clientUID = strings.TrimSpace(clientUID)
	deviceID = utils.NormalizeDeviceID(deviceID)

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", time.Time{}, err
	}

	nonce := base64.RawURLEncoding.EncodeToString(raw)
	expiresAt := s.now().Add(s.ttl)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.pruneExpiredLocked()
	s.records[nonce] = attestationNonceRecord{
		ClientUID: clientUID,
		DeviceID:  deviceID,
		ExpiresAt: expiresAt,
	}

	return nonce, expiresAt, nil
}

func (s *AttestationNonceService) Consume(clientUID, deviceID, nonce string) bool {
	if s == nil {
		return false
	}

	clientUID = strings.TrimSpace(clientUID)
	deviceID = utils.NormalizeDeviceID(deviceID)
	nonce = strings.TrimSpace(nonce)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.pruneExpiredLocked()

	record, ok := s.records[nonce]
	if !ok {
		return false
	}
	if record.ClientUID != clientUID || record.DeviceID != deviceID {
		return false
	}

	delete(s.records, nonce)
	return true
}

func (s *AttestationNonceService) Has(clientUID, deviceID, nonce string) bool {
	if s == nil {
		return false
	}

	clientUID = strings.TrimSpace(clientUID)
	deviceID = utils.NormalizeDeviceID(deviceID)
	nonce = strings.TrimSpace(nonce)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.pruneExpiredLocked()

	record, ok := s.records[nonce]
	if !ok {
		return false
	}
	return record.ClientUID == clientUID && record.DeviceID == deviceID
}

func (s *AttestationNonceService) pruneExpiredLocked() {
	now := s.now()
	for nonce, record := range s.records {
		if !record.ExpiresAt.After(now) {
			delete(s.records, nonce)
		}
	}
}

func NewAttestationNonceHandler(depot requestClientStore, nonces *AttestationNonceService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if depot == nil || nonces == nil {
			http.Error(w, "attestation nonce service is unavailable", http.StatusInternalServerError)
			return
		}

		defer r.Body.Close()

		var req AttestationNonceRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "failed to decode request", http.StatusBadRequest)
			return
		}

		req.ClientUID = strings.TrimSpace(req.ClientUID)
		req.DeviceID = utils.NormalizeDeviceID(req.DeviceID)
		req.EKPublicB64 = strings.TrimSpace(req.EKPublicB64)
		if req.ClientUID == "" {
			http.Error(w, "client_uid is required", http.StatusBadRequest)
			return
		}
		if req.DeviceID == "" {
			http.Error(w, "device_id is required", http.StatusBadRequest)
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
		if isWindowsManagedClient(client.Attributes) && client.Status != "ISSUABLE" && client.Status != "ISSUED" {
			http.Error(w, "client is not ready for attestation", http.StatusForbidden)
			return
		}

		nonce, expiresAt, err := nonces.Issue(req.ClientUID, registeredDeviceID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(AttestationNonceResponse{
			Nonce:     nonce,
			DeviceID:  registeredDeviceID,
			ExpiresAt: expiresAt.UTC(),
		}); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}
