package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/utils"
)

type stubSecretStore struct {
	client        *mysql.Client
	updateTarget  string
	updateStatus  string
	createdSecret *mysql.CreateSecretInfo
}

func (s *stubSecretStore) GetClient(string) (*mysql.Client, error) {
	return s.client, nil
}

func (s *stubSecretStore) UpdateStatusClient(uid string, status string) error {
	s.updateTarget = uid
	s.updateStatus = status
	return nil
}

func (s *stubSecretStore) CreateSecret(info mysql.CreateSecretInfo) error {
	copied := info
	s.createdSecret = &copied
	return nil
}

func (s *stubSecretStore) GetSecret(string) (mysql.GetSecretInfo, error) {
	return mysql.GetSecretInfo{}, nil
}

func TestCreateSecretHandlerRejectsWindowsMSIUpdateSecret(t *testing.T) {
	store := &stubSecretStore{
		client: &mysql.Client{
			Uid:    "client-001",
			Status: "ISSUED",
			Attributes: map[string]interface{}{
				utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
			},
		},
	}

	body, err := json.Marshal(mysql.CreateSecretInfo{
		Target:           "client-001",
		Secret:           "secret-001",
		Available_Period: "1h",
		Pending_Period:   "1h",
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/api/secret/create", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	CreateSecretHandler(store)(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want status %d, got %d: %s", http.StatusBadRequest, rec.Code, rec.Body.String())
	}
	if store.updateStatus != "" {
		t.Fatalf("expected status not to change, got %q", store.updateStatus)
	}
	if store.createdSecret != nil {
		t.Fatal("expected secret not to be created")
	}
}

func TestCreateSecretHandlerAllowsWindowsMSIInitialActivation(t *testing.T) {
	store := &stubSecretStore{
		client: &mysql.Client{
			Uid:    "client-001",
			Status: "INACTIVE",
			Attributes: map[string]interface{}{
				utils.ClientAttributeManagedClientType: utils.ManagedClientTypeWindowsMSI,
			},
		},
	}

	body, err := json.Marshal(mysql.CreateSecretInfo{
		Target:           "client-001",
		Secret:           "secret-001",
		Available_Period: "1h",
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/admin/api/secret/create", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	CreateSecretHandler(store)(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("want status %d, got %d: %s", http.StatusCreated, rec.Code, rec.Body.String())
	}
	if store.updateStatus != "ISSUABLE" {
		t.Fatalf("expected status to change to ISSUABLE, got %q", store.updateStatus)
	}
	if store.createdSecret == nil || store.createdSecret.Type != "ACTIVATE" {
		t.Fatalf("expected activation secret to be created, got %#v", store.createdSecret)
	}
}
