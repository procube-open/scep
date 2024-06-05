package scepserver

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	kitlog "github.com/go-kit/kit/log"
	kithttp "github.com/go-kit/kit/transport/http"
	"github.com/gorilla/mux"
	"github.com/groob/finalizer/logutil"
	"github.com/pkg/errors"
	"github.com/procube-open/scep/depot/mysql"
)

func MakeHTTPHandler(e *Endpoints, svc Service, logger kitlog.Logger) http.Handler {
	opts := []kithttp.ServerOption{
		kithttp.ServerErrorLogger(logger),
		kithttp.ServerFinalizer(logutil.NewHTTPLogger(logger).LoggingFinalizer),
	}

	r := mux.NewRouter()
	r.Methods("GET").Path("/scep").Handler(kithttp.NewServer(
		e.GetEndpoint,
		decodeSCEPRequest,
		encodeSCEPResponse,
		opts...,
	))
	r.Methods("POST").Path("/scep").Handler(kithttp.NewServer(
		e.PostEndpoint,
		decodeSCEPRequest,
		encodeSCEPResponse,
		opts...,
	))

	frontendHandler := http.FileServer(http.Dir("frontend/build"))
	r.Methods("GET").Path("/caweb").HandlerFunc(indexHandler)
	r.Methods("GET").PathPrefix("/caweb/").Handler(http.StripPrefix("/caweb/", frontendHandler))

	downloadHandler := http.FileServer(http.Dir("/download"))
	r.Methods("GET").PathPrefix("/api/download/").Handler(http.StripPrefix("/api/download/", downloadHandler))

	r.Methods("GET").Path("/api/verifyCert").HandlerFunc(verifyHandler)

	r.Methods("GET").Path("/api/client").HandlerFunc(listHandler)
	r.Methods("GET").Path("/api/client/{CN}").HandlerFunc(getHandler)
	r.Methods("POST").Path("/api/client/add").HandlerFunc(addHandler)
	// r.Methods("POST").Path("/api/client/revoke").HandlerFunc(revokeHandler)
	// r.Methods("PUT").Path("/api/client/update").HandlerFunc(updateHandler)
	return r
}

// EncodeSCEPRequest encodes a SCEP HTTP Request. Used by the client.
func EncodeSCEPRequest(ctx context.Context, r *http.Request, request interface{}) error {
	req := request.(SCEPRequest)
	params := r.URL.Query()
	params.Set("operation", req.Operation)
	switch r.Method {
	case "GET":
		if len(req.Message) > 0 {
			var msg string
			if req.Operation == "PKIOperation" {
				msg = base64.URLEncoding.EncodeToString(req.Message)
			} else {
				msg = string(req.Message)
			}
			params.Set("message", msg)
		}
		r.URL.RawQuery = params.Encode()
		return nil
	case "POST":
		body := bytes.NewReader(req.Message)
		// recreate the request here because IIS does not support chunked encoding by default
		// and Go doesn't appear to set Content-Length if we use an io.ReadCloser
		u := r.URL
		u.RawQuery = params.Encode()
		rr, err := http.NewRequest("POST", u.String(), body)
		rr.Header.Set("Content-Type", "application/octet-stream")
		if err != nil {
			return errors.Wrapf(err, "creating new POST request for %s", req.Operation)
		}
		*r = *rr
		return nil
	default:
		return fmt.Errorf("scep: %s method not supported", r.Method)
	}
}

const maxPayloadSize = 2 << 20

func decodeSCEPRequest(ctx context.Context, r *http.Request) (interface{}, error) {
	msg, err := message(r)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()

	request := SCEPRequest{
		Message:   msg,
		Operation: r.URL.Query().Get("operation"),
	}

	return request, nil
}

// extract message from request
func message(r *http.Request) ([]byte, error) {
	switch r.Method {
	case "GET":
		var msg string
		q := r.URL.Query()
		if _, ok := q["message"]; ok {
			msg = q.Get("message")
		}
		op := q.Get("operation")
		if op == "PKIOperation" {
			msg2, err := url.PathUnescape(msg)
			if err != nil {
				return nil, err
			}
			return base64.StdEncoding.DecodeString(msg2)
		}
		return []byte(msg), nil
	case "POST":
		return io.ReadAll(io.LimitReader(r.Body, maxPayloadSize))
	default:
		return nil, errors.New("method not supported")
	}
}

// EncodeSCEPResponse writes a SCEP response back to the SCEP client.
func encodeSCEPResponse(ctx context.Context, w http.ResponseWriter, response interface{}) error {
	resp := response.(SCEPResponse)
	if resp.Err != nil {
		http.Error(w, resp.Err.Error(), http.StatusInternalServerError)
		return nil
	}
	w.Header().Set("Content-Type", contentHeader(resp.operation, resp.CACertNum))
	w.Write(resp.Data)
	return nil
}

// DecodeSCEPResponse decodes a SCEP response
func DecodeSCEPResponse(ctx context.Context, r *http.Response) (interface{}, error) {
	if r.StatusCode != http.StatusOK && r.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
		return nil, fmt.Errorf("http request failed with status %s, msg: %s",
			r.Status,
			string(body),
		)
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxPayloadSize))
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	resp := SCEPResponse{
		Data: data,
	}
	header := r.Header.Get("Content-Type")
	if header == certChainHeader {
		// we only set it to two to indicate a cert chain.
		// the actual number of certs will be in the payload.
		resp.CACertNum = 2
	}
	return resp, nil
}

const (
	certChainHeader = "application/x-x509-ca-ra-cert"
	leafHeader      = "application/x-x509-ca-cert"
	pkiOpHeader     = "application/x-pki-message"
)

func contentHeader(op string, certNum int) string {
	switch op {
	case "GetCACert":
		if certNum > 1 {
			return certChainHeader
		}
		return leafHeader
	case "PKIOperation":
		return pkiOpHeader
	default:
		return "text/plain"
	}
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile("frontend/build/index.html")
	if err != nil {
		http.Error(w, "Failed to read index.html", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html")
	w.Write(data)
}

type resClient struct {
	Uid        string                 `json:"uid"`
	Attributes map[string]interface{} `json:"attributes"`
}

func verifyHandler(w http.ResponseWriter, r *http.Request) {
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

	depotPath := envString("SCEP_FILE_DEPOT", "ca-certs")
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
	dsn := envString("SCEP_DSN", "")
	depot, err := mysql.OpenTable(dsn)
	if err != nil {
		res := ErrResp_1{Message: "Failed to open table"}
		w.WriteHeader(http.StatusInternalServerError)
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
		res := resClient{
			Uid:        client.Uid,
			Attributes: client.Attributes,
		}
		b, _ := json.Marshal(res)
		w.Write(b)
	}
}

func getHandler(w http.ResponseWriter, r *http.Request) {
	params := mux.Vars(r)
	dsn := envString("SCEP_DSN", "")
	depot, err := mysql.OpenTable(dsn)
	if err != nil {
		http.Error(w, "Failed to open table", http.StatusInternalServerError)
		return
	}
	c, err := depot.GetClient(params["CN"])
	if err != nil {
		http.Error(w, "Failed to list certificate", http.StatusInternalServerError)
		return
	}
	res := resClient{
		Uid:        c.Uid,
		Attributes: c.Attributes,
	}
	w.Header().Set("Content-Type", "application/json")
	b, _ := json.Marshal(res)
	w.Write(b)
}

func listHandler(w http.ResponseWriter, r *http.Request) {
	dsn := envString("SCEP_DSN", "")
	depot, err := mysql.OpenTable(dsn)
	if err != nil {
		http.Error(w, "Failed to open table", http.StatusInternalServerError)
		return
	}
	clientList, err := depot.GetClientList()
	if err != nil {
		http.Error(w, "Failed to list certificate", http.StatusInternalServerError)
		return
	}
	var list []resClient
	for _, c := range clientList {
		list = append(list, resClient{
			Uid:        c.Uid,
			Attributes: c.Attributes,
		})
	}
	w.Header().Set("Content-Type", "application/json")
	b, _ := json.Marshal(list)
	w.Write(b)
}

func addHandler(w http.ResponseWriter, r *http.Request) {
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
	dsn := envString("SCEP_DSN", "")
	depot, err := mysql.OpenTable(dsn)
	if err != nil {
		http.Error(w, "Failed to open table", http.StatusInternalServerError)
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

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}
