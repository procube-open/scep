package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/procube-open/scep/depot/mysql"
)

func CreateSecretHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer r.Body.Close()
		var secret mysql.SecretInfo
		err = json.Unmarshal(body, &secret)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if strings.Contains(secret.Target, "\\") || strings.Contains(secret.Secret, "\\") {
			http.Error(w, "Target contains backslash", http.StatusInternalServerError)
			return
		}
		client, err := depot.GetClient(secret.Target)
		if err != nil {
			http.Error(w, "Target not found", http.StatusInternalServerError)
			return
		}
		if secret.Type != "ACTIVATE" && secret.Type != "UPDATE" {
			http.Error(w, "Invalid secret type", http.StatusInternalServerError)
			return
		}
		if secret.Type == "ACTIVATE" {
			if client.Status != "INACTIVE" {
				http.Error(w, "Client is not in INACTIVE state", http.StatusInternalServerError)
				return
			}
			duration, err := time.ParseDuration(secret.Available_Period)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			err = depot.UpdateStatusClient(secret.Target, "ISSUABLE")
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			time.AfterFunc(duration, func() {
				depot.DeleteSecret(secret.Target + "\\" + secret.Secret)
				depot.UpdateStatusClient(secret.Target, "INACTIVE")
			})
		} else if secret.Type == "UPDATE" {
			if client.Status != "ISSUED" {
				http.Error(w, "Client is not in ISSUED state", http.StatusInternalServerError)
				return
			}
			duration, err := time.ParseDuration(secret.Available_Period)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			if _, err := time.ParseDuration(secret.Pending_Period); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			err = depot.UpdateStatusClient(secret.Target, "UPDATABLE")
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			time.AfterFunc(duration, func() {
				depot.DeleteSecret(secret.Target + "\\" + secret.Secret)
				depot.UpdateStatusClient(secret.Target, "ISSUED")
			})
		}
		err = depot.CreateSecret(secret)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusCreated)

	}
}
