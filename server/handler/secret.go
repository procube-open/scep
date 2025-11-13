package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/mux"
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
		var secret mysql.CreateSecretInfo
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
		if client.Status == "INACTIVE" {
			err = depot.UpdateStatusClient(secret.Target, "ISSUABLE")
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			secret.Type = "ACTIVATE"
		} else if client.Status == "ISSUED" {
			if _, err := time.ParseDuration(secret.Pending_Period); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			err = depot.UpdateStatusClient(secret.Target, "UPDATABLE")
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			secret.Type = "UPDATE"
		} else {
			http.Error(w, "Client is not in INACTIVE or ISSUED state", http.StatusInternalServerError)
			return
		}
		err = depot.CreateSecret(secret)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusCreated)

	}
}

func GetSecretHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		params := mux.Vars(r)
		secrets, err := depot.GetSecret(params["CN"])
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		body, err := json.Marshal(secrets)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	}
}
