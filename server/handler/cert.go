package handler

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/mux"
	"github.com/pkg/errors"
	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/utils"

	"software.sslmate.com/src/go-pkcs12"
)

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

func checkIfRevoked(cert *x509.Certificate, revokedCerts []pkix.RevokedCertificate) bool {
	for _, revokedCert := range revokedCerts {
		if cert.SerialNumber.Cmp(revokedCert.SerialNumber) == 0 {
			return true
		}
	}
	return false
}

func returnError(w http.ResponseWriter, message string, status int) {
	type ErrResp struct {
		Message string `json:"message"`
	}
	res := ErrResp{Message: message}
	w.WriteHeader(status)
	b, _ := json.Marshal(res)
	w.Write(b)
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

		depotPath := utils.EnvString("SCEP_FILE_DEPOT", "ca-certs")
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

		rcs, err := depot.GetRCs()
		if err != nil {
			res := ErrResp_1{Message: "Failed to get RCs"}
			w.WriteHeader(http.StatusInternalServerError)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
		if checkIfRevoked(cert, rcs) {
			res := ErrResp_1{
				Message: "Certificate is revoked",
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
				Status:     client.Status,
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
		secret, err := depot.GetSecret(info.Uid)
		if err != nil || secret.Secret != info.Secret {
			res := ErrResp{Message: "Failed to create certificate"}
			w.WriteHeader(http.StatusUnauthorized)
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
	caPass := utils.EnvString("SCEP_CA_PASS", "")
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

func AddCertHandler(depot *mysql.MySQLDepot) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		decoder := json.NewDecoder(r.Body)
		type certJson struct {
			CertData string `json:"cert_pem"`
		}
		var encodedCert certJson
		err := decoder.Decode(&encodedCert)
		if err != nil {
			returnError(w, "cert_pem is required", http.StatusInternalServerError)
			return
		}
		if encodedCert.CertData == "" {
			returnError(w, "No certificate data", http.StatusInternalServerError)
			return
		}

		// 証明書のデコード
		decodedCert, err := url.PathUnescape(encodedCert.CertData)
		if err != nil {
			returnError(w, "Failed to decode certificate", http.StatusInternalServerError)
			return
		}

		// 証明書のパース
		certBlock, _ := pem.Decode([]byte(decodedCert))
		if certBlock == nil {
			returnError(w, "Failed to parse certificate", http.StatusInternalServerError)
			return
		}
		certX509, err := x509.ParseCertificate(certBlock.Bytes)
		if err != nil {
			returnError(w, "Failed to parse certificate", http.StatusInternalServerError)
			return
		}

		// シリアル番号の一致確認
		nextSerial, err := depot.GetNextSerial()
		if err != nil {
			returnError(w, "Failed to get next serial number", http.StatusInternalServerError)
			return
		}
		if nextSerial.Cmp(certX509.SerialNumber) != 0 {
			returnError(w, "Serial number is not matched", http.StatusInternalServerError)
			return
		}

		// クライアントの状態確認
		client, err := depot.GetClient(certX509.Subject.CommonName)
		if err != nil {
			returnError(w, "Failed to get client", http.StatusInternalServerError)
			return
		}
		if client == nil {
			returnError(w, "Client not found", http.StatusInternalServerError)
			return
		}
		if client.Status != "ISSUABLE" && client.Status != "UPDATABLE" {
			returnError(w, "Client is not in ISSUABLE or UPDATABLE state", http.StatusInternalServerError)
			return
		}

		// 証明書の検証
		depotPath := utils.EnvString("SCEP_FILE_DEPOT", "ca-certs")
		ca_crt, _ := os.ReadFile(depotPath + "/ca.crt")
		caCertBlock, _ := pem.Decode(ca_crt)
		caCert, _ := x509.ParseCertificate(caCertBlock.Bytes)
		certPool := x509.NewCertPool()
		certPool.AddCert(caCert)
		opts := x509.VerifyOptions{
			Roots:     certPool,
			KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		}
		if _, err := certX509.Verify(opts); err != nil {
			returnError(w, "Failed to verify certificate", http.StatusUnauthorized)
			return
		}

		// 証明書の追加
		secret, err := depot.GetSecret(certX509.Subject.CommonName)
		if err != nil {
			returnError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		cn := certX509.Subject.CommonName
		challenge := cn + "\\" + secret.Secret
		_, err = depot.Serial()
		if err != nil {
			returnError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, err = depot.HasCN(cn, 0, certX509, true)
		if err != nil {
			returnError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if err := depot.Put(cn, certX509, challenge); err != nil {
			returnError(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
}
