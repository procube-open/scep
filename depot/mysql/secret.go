package mysql

import (
	"database/sql"
	"errors"
	"time"
)

type CreateSecretInfo struct {
	Secret           string `json:"secret"`
	Type             string `json:"type"`
	Target           string `json:"target"`
	Available_Period string `json:"available_period"`
	Pending_Period   string `json:"pending_period"`
}

type GetSecretInfo struct {
	Secret         string    `json:"secret"`
	Type           string    `json:"type"`
	Delete_At      time.Time `json:"delete_at"`
	Pending_Period string    `json:"pending_period"`
}

func (d *MySQLDepot) CreateSecret(info CreateSecretInfo) error {
	now := time.Now()
	challenge := info.Target + "\\" + info.Secret
	duration, err := time.ParseDuration(info.Available_Period)
	if err != nil {
		return err
	}
	deleteAt := now.Add(duration)
	_, err = d.db.Exec("INSERT INTO secrets (challenge, secret, target, type, created_at, delete_at, pending_period) VALUES (?, ?, ?, ?, ?, ?, ?)",
		challenge, info.Secret, info.Target, info.Type, now, deleteAt, info.Pending_Period)
	if err != nil {
		return err
	}
	return nil
}

func (d *MySQLDepot) DeleteSecret(target string) error {
	_, err := d.db.Exec("DELETE FROM secrets WHERE target = ?", target)
	return err
}

func (d *MySQLDepot) GetSecret(target string) (GetSecretInfo, error) {
	var secret GetSecretInfo
	rows, err := d.db.Query("SELECT secret, type, delete_at, pending_period FROM secrets WHERE target = ?", target)
	if err != nil {
		return secret, err
	}
	defer rows.Close()
	if !rows.Next() {
		return secret, sql.ErrNoRows
	}
	err = rows.Scan(&secret.Secret, &secret.Type, &secret.Delete_At, &secret.Pending_Period)
	return secret, err
}

func (d *MySQLDepot) CheckSecretExpiration() error {
	rows, err := d.db.Query("SELECT target FROM secrets WHERE delete_at < NOW()")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var target string
		err := rows.Scan(&target)
		if err != nil {
			return err
		}
		client, err := d.GetClient(target)
		if err != nil {
			return err
		}
		if client.Status == "ISSUABLE" {
			_, err = d.db.Exec("UPDATE clients SET status = 'INACTIVE' WHERE uid = ?", target)
			if err != nil {
				return err
			}
		} else if client.Status == "UPDATABLE" {
			_, err = d.db.Exec("UPDATE clients SET status = 'ISSUED' WHERE uid = ?", target)
			if err != nil {
				return err
			}
		} else {
			return errors.New("client is not issuable or updatable")
		}

		err = d.DeleteSecret(target)
		if err != nil {
			return err
		}

	}
	return nil
}
