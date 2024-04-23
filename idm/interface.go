package idm

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type User *struct {
	Uid      string `json:"uid"`
	Password string `json:"password"`
}

type Cert struct {
	CertIss     string `json:"certIss"`
	CertExp     string `json:"certExp"`
	Certificate string `json:"certificate"`
}

type RevokeCertificate *struct {
	Certificate string `json:"certificate"`
}

func GETUser(geturl string, challenge string) error {
	var user User
	pair := strings.Split(challenge, "\\")

	// interface取得
	u, err := url.Parse(geturl + "/" + pair[0])
	if err != nil {
		return err
	}

	req, _ := http.NewRequest(http.MethodGet, u.String(), nil)
	addHeader(req)

	client := new(http.Client)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 400 {
		return errors.New("user not found")
	} else if resp.StatusCode != 200 {
		return errors.New("IDM is invalid")
	}
	body, _ := io.ReadAll(resp.Body)

	//Go構造体化
	if err := json.Unmarshal(body, &user); err != nil {
		return err
	}

	//challenge確認
	if user.Password != pair[1] {
		return errors.New("incorrect password")
	} else {
		return nil
	}
}

func PUTCertificate(url string, crtStr string, notBefore time.Time, notAfter time.Time) error {
	cert := Cert{
		Certificate: crtStr,
		CertIss:     notBefore.Format("2006-01-02T15:04:05.000Z"),
		CertExp:     notAfter.Format("2006-01-02T15:04:05.000Z"),
	}

	certJson, err := json.Marshal(cert)
	if err != nil {
		return err
	}
	// interface取得
	req, _ := http.NewRequest("PUT", url, bytes.NewBuffer(certJson))
	addHeader(req)
	req.Header.Add("Content-Type", "application/json")

	client := new(http.Client)
	resp, _err := client.Do(req)
	if _err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return err
	}
	return nil
}

func GETUserByCN(url string) ([]byte, error) {
	// interface取得
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	addHeader(req)

	client := new(http.Client)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == 400 {
		return nil, errors.New("NotFound")
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	return body, nil
}

func GETRCs(url string) ([]RevokeCertificate, error) {
	var rcs []RevokeCertificate

	// interface取得
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	addHeader(req)

	client := new(http.Client)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, err
	}
	body, _ := io.ReadAll(resp.Body)

	//Go構造体化
	if err := json.Unmarshal(body, &rcs); err != nil {
		return nil, err
	}

	return rcs, nil
}

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}

func addHeader(req *http.Request) {
	header0 := envString("SCEP_IDM_HEADER0", "")
	if header0 != "" && strings.Contains(header0, ":") {
		header0kv := strings.Split(header0, ":")
		req.Header.Add(header0kv[0], header0kv[1])
	}
	header1 := envString("SCEP_IDM_HEADER1", "")
	if header1 != "" && strings.Contains(header1, ":") {
		header1kv := strings.Split(header1, ":")
		req.Header.Add(header1kv[0], header1kv[1])
	}
	req.Header.Add("HTTP_SYSTEMACCOUNT", "SCEP_SERVER")
}
