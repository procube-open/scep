package handler

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/gorilla/mux"
)

func IndexHandler(frontendPath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, err := os.ReadFile(frontendPath + "/index.html")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write(data)
	}
}

func ListFilesHandler(basePath string) http.HandlerFunc {
	type FileInfo struct {
		Name    string      `json:"name"`
		Size    int64       `json:"size"`
		Mode    os.FileMode `json:"mode"`
		ModTime time.Time   `json:"mod_time"`
		IsDir   bool        `json:"is_dir"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		params := mux.Vars(r)
		path := params["path"]
		files, err := os.ReadDir(filepath.Join(basePath, path))
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		var list []FileInfo
		for _, f := range files {
			info, err := f.Info()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			list = append(list, FileInfo{
				Name:    info.Name(),
				Size:    info.Size(),
				Mode:    info.Mode(),
				ModTime: info.ModTime(),
				IsDir:   info.IsDir(),
			})
		}

		w.Header().Set("Content-Type", "application/json")
		b, err := json.Marshal(list)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Write(b)
	}
}
