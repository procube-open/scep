package idm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type User *struct {
	Uid         string `json:"uid"`
	Password    string `json:"password"`
	CertIss     string `json:"certIss"`
	CertExp     string `json:"certExp"`
	Certificate string `json:"certificate"`
}

func GETInterface(url string, challenge string) (User, error) {
	var users []User

	// interface取得
	gitAuthHeaderName := "X-Github-Token"
	gitAuthHeaderValue := "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"
	auth8090HeaderName := "HTTP_SYSTEMACCOUNT"
	auth8090HeaderValue := "SCEP_SERVER"

	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set(gitAuthHeaderName, gitAuthHeaderValue)
	req.Header.Add(auth8090HeaderName, auth8090HeaderValue)
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

func PUTCertificate(url string, challenge string, crtStr string) error {
	user, err := GETInterface(url, challenge)

	puturl := url + "/" + user.Uid
	user.Certificate = crtStr
	userJson, _ := json.Marshal(user)
	// interface取得
	gitAuthHeaderName := "X-Github-Token"
	gitAuthHeaderValue := "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"
	auth8090HeaderName := "HTTP_SYSTEMACCOUNT"
	auth8090HeaderValue := "SCEP_SERVER"

	req, _ := http.NewRequest("PUT", puturl, bytes.NewBuffer(userJson))
	req.Header.Set(gitAuthHeaderName, gitAuthHeaderValue)
	req.Header.Add(auth8090HeaderName, auth8090HeaderValue)
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
