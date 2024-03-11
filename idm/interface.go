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
	Uid         string `json:"uid"`
	Password    string `json:"password"`
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
	addHeader(req)

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
		fmt.Println(err)
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

func PUTCertificate(url string, challenge string, crtStr string, notBefore time.Time, notAfter time.Time) error {
	user, err := GETUser(url, challenge)
	if err != nil {
		fmt.Println("GET Error", err)
		return errors.New("GET Error")
	}
	puturl := url + "/" + user.Uid
	user.Certificate = crtStr
	user.CertIss = notBefore.Format("2006-01-02T15:04:05.000Z")
	user.CertExp = notAfter.Format("2006-01-02T15:04:05.000Z")
	userJson, err := json.Marshal(user)
	if err != nil {
		fmt.Println("Encode Error", err)
		return errors.New("Encode Error")
	}
	// interface取得
	req, _ := http.NewRequest("PUT", puturl, bytes.NewBuffer(userJson))
	addHeader(req)

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
	addHeader(req)

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

	auth8090HeaderName := "HTTP_SYSTEMACCOUNT"
	auth8090HeaderValue := "SCEP_SERVER"
	req.Header.Add(auth8090HeaderName, auth8090HeaderValue)
}
