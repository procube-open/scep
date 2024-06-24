package mysql

import (
	"database/sql"
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
