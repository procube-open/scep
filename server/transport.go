package scepserver

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"

	kitlog "github.com/go-kit/kit/log"
	kithttp "github.com/go-kit/kit/transport/http"
	"github.com/gorilla/mux"
	"github.com/groob/finalizer/logutil"
	"github.com/pkg/errors"
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
	r.HandleFunc("/", indexHandler)
	r.HandleFunc("/static/{script}/{filename}", staticHandler)
	r.HandleFunc("/manifest.json", manifestHandler)
	r.HandleFunc("/favicon.ico", faviconHandler)
	r.HandleFunc("/logo192.png", logo192Handler)
	r.HandleFunc("/logo512.png", logo512Handler)

	//download client
	r.HandleFunc("/download/{client}", downloadHandler)

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
	data, _ := os.ReadFile("frontend/index.html")
	w.Write(data)
}

func staticHandler(w http.ResponseWriter, r *http.Request) {
	params := mux.Vars(r)
	if params["script"] == "js" {
		w.Header().Set("Content-Type", "application/javascript")
	} else if params["script"] == "css" {
		w.Header().Set("Content-Type", "text/css")
	}
	data, _ := os.ReadFile("frontend/static/" + params["script"] + "/" + params["filename"])
	w.Write(data)
}

func manifestHandler(w http.ResponseWriter, r *http.Request) {
	data, _ := os.ReadFile("frontend/manifest.json")
	w.Write(data)
}

func faviconHandler(w http.ResponseWriter, r *http.Request) {
	data, _ := os.ReadFile("frontend/favicon.ico")
	w.Write(data)
}

func logo192Handler(w http.ResponseWriter, r *http.Request) {
	data, _ := os.ReadFile("frontend/logo192.png")
	w.Write(data)
}

func logo512Handler(w http.ResponseWriter, r *http.Request) {
	data, _ := os.ReadFile("frontend/logo512.png")
	w.Write(data)
}

func downloadHandler(w http.ResponseWriter, r *http.Request) {
	params := mux.Vars(r)
	data, err := os.ReadFile("/client/" + params["client"])
	if err != nil {
		w.Write([]byte(params["client"] + " not found"))
	} else {
		w.Write(data)
	}
}
