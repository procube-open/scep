package scepserver

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/procube-open/scep/utils"
)

const (
	defaultAttestationPreregCheckWindow = time.Minute
	defaultAttestationPreregCheckLimit  = 30

	preregCheckResultReady          = "ready"
	preregCheckResultClientNotFound = "client_not_found"
	preregCheckResultDeviceMismatch = "device_id_mismatch"
	preregCheckResultNotIssuableYet = "not_issuable_yet"
)

type AttestationPreregCheckRequest struct {
	ClientUID string `json:"client_uid"`
	DeviceID  string `json:"device_id"`
}

type AttestationPreregCheckResponse struct {
	Result string `json:"result"`
}

type AttestationPreregCheckRateLimiter struct {
	mu      sync.Mutex
	limit   int
	window  time.Duration
	now     func() time.Time
	records map[string][]time.Time
}

func NewAttestationPreregCheckRateLimiter(limit int, window time.Duration) *AttestationPreregCheckRateLimiter {
	if limit <= 0 {
		limit = defaultAttestationPreregCheckLimit
	}
	if window <= 0 {
		window = defaultAttestationPreregCheckWindow
	}
	return &AttestationPreregCheckRateLimiter{
		limit:   limit,
		window:  window,
		now:     time.Now,
		records: make(map[string][]time.Time),
	}
}

func (l *AttestationPreregCheckRateLimiter) Allow(key string) bool {
	if l == nil {
		return true
	}

	key = strings.TrimSpace(key)
	if key == "" {
		key = "unknown"
	}

	now := l.now()
	cutoff := now.Add(-l.window)

	l.mu.Lock()
	defer l.mu.Unlock()

	current := l.records[key][:0]
	for _, recordedAt := range l.records[key] {
		if recordedAt.After(cutoff) {
			current = append(current, recordedAt)
		}
	}
	if len(current) >= l.limit {
		l.records[key] = current
		return false
	}
	l.records[key] = append(current, now)
	return true
}

func NewAttestationPreregCheckHandler(depot requestClientStore, limiter *AttestationPreregCheckRateLimiter) http.HandlerFunc {
	if limiter == nil {
		limiter = NewAttestationPreregCheckRateLimiter(0, 0)
	}

	return func(w http.ResponseWriter, r *http.Request) {
		if depot == nil {
			http.Error(w, "attestation preregistration service is unavailable", http.StatusInternalServerError)
			return
		}

		if !limiter.Allow(remoteAddrKey(r)) {
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}

		defer r.Body.Close()

		var req AttestationPreregCheckRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "failed to decode request", http.StatusBadRequest)
			return
		}

		req.ClientUID = strings.TrimSpace(req.ClientUID)
		req.DeviceID = utils.NormalizeDeviceID(req.DeviceID)
		switch {
		case req.ClientUID == "":
			http.Error(w, "client_uid is required", http.StatusBadRequest)
			return
		case req.DeviceID == "":
			http.Error(w, "device_id is required", http.StatusBadRequest)
			return
		}

		result := AttestationPreregCheckResponse{Result: preregCheckResultReady}

		client, err := depot.GetClient(req.ClientUID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if client == nil {
			result.Result = preregCheckResultClientNotFound
			writePreregCheckJSON(w, result)
			return
		}

		registeredDeviceID, ok := lookupDeviceID(client.Attributes)
		if !ok || registeredDeviceID != req.DeviceID {
			result.Result = preregCheckResultDeviceMismatch
			writePreregCheckJSON(w, result)
			return
		}

		switch client.Status {
		case "ISSUABLE", "ISSUED":
		default:
			result.Result = preregCheckResultNotIssuableYet
		}

		writePreregCheckJSON(w, result)
	}
}

func writePreregCheckJSON(w http.ResponseWriter, result AttestationPreregCheckResponse) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

func remoteAddrKey(r *http.Request) string {
	if r == nil {
		return "unknown"
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err != nil || host == "" {
		host = strings.TrimSpace(r.RemoteAddr)
	}
	if host == "" {
		return "unknown"
	}
	return host
}
