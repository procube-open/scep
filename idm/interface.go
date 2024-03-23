package idm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
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

func GETUser(url string, challenge string) (User, error) {
	var users []User

	// interface取得
	req, _ := http.NewRequest(http.MethodGet, url, nil)
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

	client := new(http.Client)
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("Error Request:", err)
		return nil, errors.New("IDM is invalid")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Println("Error Response:", resp.Status)
		return nil, errors.New("IDM is invalid")
	}
	body, _ := io.ReadAll(resp.Body)

	//Go構造体化
	if err := json.Unmarshal(body, &users); err != nil {
		fmt.Println("Unmarshal Error:" + err.Error())
		return nil, errors.New("invalid JSON")
	}

	//challenge確認
	pair := strings.Split(challenge, "\\")
	index := checkUsers(users, pair[0], pair[1])
	if index != -1 {
		return users[index], nil
	} else {
		fmt.Println("cannot find user")
		return nil, errors.New("invalid uid or password")
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
		fmt.Println("Encode Error", err)
		return errors.New("encode error")
	}
	// interface取得
	req, _ := http.NewRequest("PUT", url, bytes.NewBuffer(certJson))
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
	req.Header.Add("Content-Type", "application/json")

	client := new(http.Client)
	resp, _err := client.Do(req)
	if _err != nil {
		fmt.Println("Error Request:", err)
		return errors.New("IDM is invalid")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Println("Error Response:", resp.Status)
		return errors.New("IDM is invalid")
	}
	return nil
}

func GETUserByCN(url string) ([]byte, error) {
	// interface取得
	req, _ := http.NewRequest(http.MethodGet, url, nil)
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

	client := new(http.Client)
	resp, err := client.Do(req)
	if resp.StatusCode == 400 {
		return nil, errors.New("NotFound")
	} else if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	return body, nil
}

func checkUsers(slice []User, uid string, secret string) int {
	for i, s := range slice {
		if s.Uid == uid && s.Password == secret {
			return i
		}
	}
	return -1
}

func GETRCs(url string) ([]RevokeCertificate, error) {
	var rcs []RevokeCertificate

	// interface取得
	req, _ := http.NewRequest(http.MethodGet, url, nil)
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

	client := new(http.Client)
	resp, err := client.Do(req)
	if err != nil {
		fmt.Println("Error Request:", err)
		return nil, errors.New("IDM is invalid")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Println("Error Response:", resp.Status)
		return nil, errors.New("IDM is invalid")
	}
	body, _ := io.ReadAll(resp.Body)

	//Go構造体化
	if err := json.Unmarshal(body, &rcs); err != nil {
		fmt.Println(err)
		return nil, errors.New("invalid JSON")
	}

	return rcs, nil
}

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}
