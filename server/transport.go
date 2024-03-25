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
	"github.com/procube-open/scep/idm"
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

	// frontend
	r.HandleFunc("/caweb", indexHandler)
	r.HandleFunc("/caweb/static/{script}/{filename}", staticHandler)
	r.HandleFunc("/caweb/manifest.json", manifestHandler)
	r.HandleFunc("/caweb/favicon.ico", faviconHandler)
	r.HandleFunc("/caweb/logo192.png", logo192Handler)
	r.HandleFunc("/caweb/logo512.png", logo512Handler)

	//download client
	r.HandleFunc("/download/{client}", downloadHandler)

	//get user object
	r.HandleFunc("/userObject", userHandler)

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
	data, _ := os.ReadFile("frontend/build/index.html")
	w.Write(data)
}

func staticHandler(w http.ResponseWriter, r *http.Request) {
	params := mux.Vars(r)
	if params["script"] == "js" {
		w.Header().Set("Content-Type", "application/javascript")
	} else if params["script"] == "css" {
		w.Header().Set("Content-Type", "text/css")
	}
	data, err := os.ReadFile("frontend/build/static/" + params["script"] + "/" + params["filename"])
	if err != nil {
		w.Write([]byte(err.Error()))
	}
	w.Write(data)
}

func manifestHandler(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile("frontend/build/manifest.json")
	if err != nil {
		w.Write([]byte(err.Error()))
	}
	w.Write(data)
}

func faviconHandler(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile("frontend/build/favicon.ico")
	if err != nil {
		w.Write([]byte(err.Error()))
	}
	w.Write(data)
}

func logo192Handler(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile("frontend/build/logo192.png")
	if err != nil {
		w.Write([]byte(err.Error()))
	}
	w.Write(data)
}

func logo512Handler(w http.ResponseWriter, r *http.Request) {
	data, err := os.ReadFile("frontend/build/logo512.png")
	if err != nil {
		w.Write([]byte(err.Error()))
	}
	w.Write(data)
}

func downloadHandler(w http.ResponseWriter, r *http.Request) {
	params := mux.Vars(r)
	data, err := os.ReadFile("/client/" + params["client"])
	if err != nil {
		w.Write([]byte(err.Error()))
	} else {
		w.Write(data)
	}
}

func userHandler(w http.ResponseWriter, r *http.Request) {
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

	depotPath := envString("SCEP_FILE_DEPOT", "idm-depot")
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
			Message:     "Failed to validate certificate",
			Certificate: string(decodedCert),
			CaCert:      string(ca_crt),
		}
		w.WriteHeader(http.StatusUnauthorized)
		b, _ := json.Marshal(res)
		w.Write(b)
		return
	}
	u, err := url.Parse(envString("SCEP_IDM_USERS_URL", "") + "/" + cert.Subject.CommonName)
	if err != nil {
		res := ErrResp_1{Message: "Failed to parse url"}
		w.WriteHeader(http.StatusInternalServerError)
		b, _ := json.Marshal(res)
		w.Write(b)
		return
	}

	body, err := idm.GETUserByCN(u.String())
	if err != nil {
		if err.Error() == "NotFound" {
			res := ErrResp_4{
				Message: "User Not Found",
				User:    cert.Subject.CommonName,
			}
			w.WriteHeader(http.StatusUnauthorized)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		} else {
			res := ErrResp_1{
				Message: err.Error(),
			}
			w.WriteHeader(http.StatusBadGateway)
			b, _ := json.Marshal(res)
			w.Write(b)
			return
		}
	}
	w.Write(body)
}

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

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}
