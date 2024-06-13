package handler

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gorilla/mux"
	"github.com/procube-open/scep/depot/mysql"
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
		res := ResClient{
			Uid:        c.Uid,
			Status:     c.Status,
			Attributes: c.Attributes,
		}
		w.Header().Set("Content-Type", "application/json")
		b, _ := json.Marshal(res)
		w.Write(b)
	}
}

func ListClientHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
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
	}
}

func UpdateClientHandler(depot *mysql.MySQLDepot, dest string) http.HandlerFunc {
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
		if dest == "attributes" {
			if c.Attributes == nil {
				c.Attributes = make(map[string]interface{})
			}
			err = depot.UpdateAttributesClient(c)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		} else {
			err = depot.UpdateStatusClient(c.Uid, dest)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
		}

	}
}
