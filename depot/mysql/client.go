package mysql

import (
	"encoding/json"

	_ "github.com/go-sql-driver/mysql"
)

type Client struct {
	Uid        string                 `json:"uid"`
	Secret     string                 `json:"secret"`
	Attributes map[string]interface{} `json:"attributes"`
}

func (d *MySQLDepot) AddClient(client Client) error {
	attributesStr, err := json.Marshal(client.Attributes)
	if err != nil {
		return err
	}
	_, err = d.db.Exec("INSERT INTO clients (uid, secret, attributes) VALUES (?, ?, ?)", client.Uid, client.Secret, attributesStr)
	return err
}

func (d *MySQLDepot) GetClient(uid string) (*Client, error) {
	rows, err := d.db.Query("SELECT uid, secret, attributes FROM clients WHERE uid = ?", uid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var c Client
	var clientAttributes string
	for rows.Next() {
		err := rows.Scan(&c.Uid, &c.Secret, &clientAttributes)
		if err != nil {
			return nil, err
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	err = json.Unmarshal([]byte(clientAttributes), &c.Attributes)
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func (d *MySQLDepot) GetClientList() ([]Client, error) {
	var clients []Client
	rows, err := d.db.Query("SELECT uid, secret, attributes FROM clients")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c Client
		var clientAttributes string
		err := rows.Scan(&c.Uid, &c.Secret, &clientAttributes)
		if err != nil {
			return nil, err
		}
		err = json.Unmarshal([]byte(clientAttributes), &c.Attributes)
		if err != nil {
			return nil, err
		}
		clients = append(clients, c)
	}
	return clients, nil
}
