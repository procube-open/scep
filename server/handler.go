package scepserver

import (
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/mux"
	"github.com/pkg/errors"
	"github.com/procube-open/scep/depot/mysql"
	"software.sslmate.com/src/go-pkcs12"
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

func CertsHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		params := mux.Vars(r)
		certs, err := depot.GetCertsByCN(params["CN"])
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		b, _ := json.Marshal(certs)
		w.Write(b)
	}
}

func VerifyHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type ErrResp_1 struct {
			Message string `json:"message"`
		}
		type ErrResp_2 struct {
			Message   string `json:"message"`
			NotBefore string `json:"notBefore"`
			NotAfter  string `json:"notAfter"`
			Date      string `json:"Date"`
		}
		type ErrResp_3 struct {
			Message     string `json:"message"`
			Certificate string `json:"certificate"`
			CaCert      string `json:"cacert"`
		}
		type ErrResp_4 struct {
			Message string `json:"message"`
			User    string `json:"user"`
		}

		encodedCert := r.Header["X-Mtls-Clientcert"]
		w.Header().Set("Content-Type", "application/json")
		if len(encodedCert) != 1 {
			res := ErrResp_1{Message: "No Certificate"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}

		decodedCert, err := url.PathUnescape(encodedCert[0])
		if err != nil {
			res := ErrResp_1{Message: "Decode header failed"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}

		certBlock, _ := pem.Decode([]byte(decodedCert))
		cert, err := x509.ParseCertificate(certBlock.Bytes)
		if err != nil {
			res := ErrResp_1{Message: "Parse Certificate failed"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}

		now := time.Now()
		if now.After(cert.NotAfter) || now.Before(cert.NotBefore) {
			res := ErrResp_2{
				Message:   "Certificate is expired",
				NotBefore: cert.NotBefore.String(),
				NotAfter:  cert.NotAfter.String(),
				Date:      now.String(),
			}
			w.WriteHeader(http.StatusUnauthorized)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}

		depotPath := EnvString("SCEP_FILE_DEPOT", "ca-certs")
		ca_crt, _ := os.ReadFile(depotPath + "/ca.crt")
		caCertBlock, _ := pem.Decode(ca_crt)
		caCert, _ := x509.ParseCertificate(caCertBlock.Bytes)
		certPool := x509.NewCertPool()
		certPool.AddCert(caCert)
		opts := x509.VerifyOptions{
			Roots:     certPool,
			KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		}

		if _, err := cert.Verify(opts); err != nil {
			res := ErrResp_3{
				Message:     "Failed to verify certificate",
				Certificate: string(decodedCert),
				CaCert:      string(ca_crt),
			}
			w.WriteHeader(http.StatusUnauthorized)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		client, err := depot.GetClient(cert.Subject.CommonName)
		if client == nil && err == nil {
			res := ErrResp_4{
				Message: "User Not Found",
				User:    cert.Subject.CommonName,
			}
			w.WriteHeader(http.StatusUnauthorized)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		} else if err != nil {
			res := ErrResp_1{Message: err.Error()}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		} else {
			res := ResClient{
				Uid:        client.Uid,
				Attributes: client.Attributes,
			}
			b, _ := json.Marshal(res)
			w.Write(b)
		}
	}
}

type createInfo *struct {
	Uid      string `json:"uid"`
	Secret   string `json:"secret"`
	Password string `json:"password"`
}

func Pkcs12Handler(depot *mysql.MySQLDepot) http.HandlerFunc {
	type ErrResp struct {
		Message string `json:"message"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		decoder := json.NewDecoder(r.Body)
		var info createInfo
		err := decoder.Decode(&info)
		if err != nil {
			res := ErrResp{Message: "Failed to decode request"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		p12, err := createPKCS12(depot, info)
		if err != nil {
			res := ErrResp{Message: err.Error()}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(p12)))
		w.Write(p12)
	}
}
func createPKCS12(depot *mysql.MySQLDepot, info createInfo) ([]byte, error) {
	var err error
	if info.Password == "" {
		return nil, errors.New("password is required")
	}
	if info.Uid != "" && info.Secret != "" {
		os.RemoveAll("/tmp/" + info.Uid)
		if err := os.Mkdir("/tmp/"+info.Uid, 0770); err != nil {
			return nil, err
		}
		// cert.pem,key.pem,csr.pemを作成
		fmt.Println("--- POST CSR myself ---")
		cmd := exec.Command("./scepclient-opt", "-uid", info.Uid, "-secret", info.Secret, "-out", "/tmp/"+info.Uid+"/")
		var out strings.Builder
		cmd.Stdout = &out
		err = cmd.Run()
		fmt.Println(out.String())
	} else {
		err = errors.New("without uid or secret params")
	}
	fmt.Println("--- finish ---")
	if err != nil {
		return nil, errors.New("Failed to create certificate")
	}
	// pkcs12形式に変換
	//X509.PrivateKey読み込み
	key, err := os.ReadFile("/tmp/" + info.Uid + "/key.pem")
	if err != nil {
		return nil, err
	}
	keyBlock, _ := pem.Decode([]byte(key))
	k, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, err
	}

	//X509.Certificate読み込み
	cert, err := os.ReadFile("/tmp/" + info.Uid + "/cert.pem")
	if err != nil {
		return nil, err
	}
	certBlock, _ := pem.Decode([]byte(cert))
	c, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, err
	}

	//X509.Certificate読み込み
	caPass := EnvString("SCEP_CA_PASS", "")
	caCerts, _, err := depot.CA([]byte(caPass))
	if err != nil {
		return nil, err
	}

	//PKCS12エンコード
	p12, err := pkcs12.LegacyDES.Encode(k, c, caCerts, info.Password)
	if err != nil {
		return nil, err
	}

	//ファイルを掃除
	os.RemoveAll("/tmp/" + info.Uid)

	return p12, nil
}

type ResClient struct {
	Uid        string                 `json:"uid"`
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
			http.Error(w, "Failed to list certificate", http.StatusInternalServerError)
			return
		}
		var list []ResClient
		for _, c := range clientList {
			list = append(list, ResClient{
				Uid:        c.Uid,
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
		if c.Secret == "" {
			res := ErrResp{Message: "Secret is required"}
			w.WriteHeader(http.StatusBadRequest)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if c.Attributes == nil {
			c.Attributes = make(map[string]interface{})
		}
		err = depot.AddClient(c)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
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
