package mysql

import (
	"encoding/json"

	_ "github.com/go-sql-driver/mysql"
)

type Client struct {
	Uid        string                 `json:"uid"`
	Status     string                 `json:"status"`
	Attributes map[string]interface{} `json:"attributes"`
}

type UpdateInfo struct {
	Uid        string                 `json:"uid"`
	Attributes map[string]interface{} `json:"attributes"`
}

func (d *MySQLDepot) AddClient(client Client, initialStatus string) error {
	attributesStr, err := json.Marshal(client.Attributes)
	if err != nil {
		return err
	}
	_, err = d.db.Exec("INSERT INTO clients (uid, status, attributes) VALUES (?, ?, ?)", client.Uid, initialStatus, attributesStr)
	return err
}

func (d *MySQLDepot) UpdateAttributesClient(info UpdateInfo) error {
	attributesStr, err := json.Marshal(info.Attributes)
	if err != nil {
		return err
	}
	_, err = d.db.Exec("UPDATE clients SET attributes = ? WHERE uid = ?", attributesStr, info.Uid)
	return err
}

func (d *MySQLDepot) UpdateStatusClient(uid string, status string) error {
	_, err := d.db.Exec("UPDATE clients SET status = ? WHERE uid = ?", status, uid)
	return err
}

func (d *MySQLDepot) GetClient(uid string) (*Client, error) {
	rows, err := d.db.Query("SELECT uid, status, attributes FROM clients WHERE uid = ?", uid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var c Client
	var clientAttributes string
	for rows.Next() {
		err := rows.Scan(&c.Uid, &c.Status, &clientAttributes)
		if err != nil {
			return nil, err
		}
	}
	if c.Uid == "" {
		return nil, nil
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
	rows, err := d.db.Query("SELECT uid, status, attributes FROM clients")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c Client
		var clientAttributes string
		err := rows.Scan(&c.Uid, &c.Status, &clientAttributes)
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
