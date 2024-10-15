package handler

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/mux"
	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/hook"
)

type ResClient struct {
	Uid        string                 `json:"uid"`
	Status     string                 `json:"status"`
	Attributes map[string]interface{} `json:"attributes"`
}

func GetClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		params := mux.Vars(r)
		c, err := depot.GetClient(params["CN"])
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if c == nil {
			w.Write([]byte("null"))
			return
		}
		res := ResClient{
			Uid:        c.Uid,
			Status:     c.Status,
			Attributes: c.Attributes,
		}
		b, _ := json.Marshal(res)
		w.Write(b)
	}
}

func ListClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "OPTIONS" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			return
		}
		clientList, err := depot.GetClientList()
		if err != nil {
			http.Error(w, "Failed to list client", http.StatusInternalServerError)
			return
		}
		var list []ResClient
		for _, c := range clientList {
			list = append(list, ResClient{
				Uid:        c.Uid,
				Status:     c.Status,
				Attributes: c.Attributes,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		b, _ := json.Marshal(list)
		w.Write(b)
	}
}

func AddClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type ErrResp struct {
			Message string `json:"message"`
		}
		decoder := json.NewDecoder(r.Body)
		var c mysql.Client
		err := decoder.Decode(&c)
		if err != nil {
			res := ErrResp{Message: "Failed to decode request"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if c.Uid == "" {
			res := ErrResp{Message: "UID is required"}
			w.WriteHeader(http.StatusBadRequest)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if strings.Contains(c.Uid, "\\") {
			res := ErrResp{Message: "UID contains backslash"}
			w.WriteHeader(http.StatusBadRequest)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if c.Attributes == nil {
			c.Attributes = make(map[string]interface{})
		}
		initialStatus := "INACTIVE"
		err = depot.AddClient(c, initialStatus)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		err = hook.AddClientHook(c.Uid)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}

func UpdateClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type ErrResp struct {
			Message string `json:"message"`
		}
		decoder := json.NewDecoder(r.Body)
		var c mysql.UpdateInfo
		err := decoder.Decode(&c)
		if err != nil {
			res := ErrResp{Message: "Failed to decode request"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if c.Attributes == nil {
			c.Attributes = make(map[string]interface{})
		}
		err = depot.UpdateAttributesClient(c)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}

func RevokeClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type ErrResp struct {
			Message string `json:"message"`
		}
		decoder := json.NewDecoder(r.Body)
		var c mysql.UpdateInfo
		err := decoder.Decode(&c)
		if err != nil {
			res := ErrResp{Message: "Failed to decode request"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		client, err := depot.GetClient(c.Uid)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if client == nil {
			res := ErrResp{Message: "Client not found"}
			w.WriteHeader(http.StatusNotFound)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if client.Status != "INACTIVE" {
			if client.Status != "ISSUABLE" {
				if err := depot.RevokeCertificate(c.Uid, time.Now()); err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
			}
			if client.Status == "ISSUABLE" || client.Status == "UPDATABLE" {
				if err := depot.DeleteSecret(c.Uid); err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
			}
			if err := depot.UpdateStatusClient(c.Uid, "INACTIVE"); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		} else {
			res := ErrResp{Message: "Client is already in INACTIVE state"}
			w.WriteHeader(http.StatusBadRequest)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
	}
}
