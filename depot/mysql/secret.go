package mysql

import (
	"time"
)

type SecretInfo struct {
	Secret           string `json:"secret"`
	Type             string `json:"type"`
	Target           string `json:"target"`
	Available_Period string `json:"available_period"`
	Pending_Period   string `json:"pending_period"`
}

func (d *MySQLDepot) CreateSecret(info SecretInfo) error {
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

func (d *MySQLDepot) DeleteSecret(challenge string) error {
	_, err := d.db.Exec("DELETE FROM secrets WHERE challenge = ?", challenge)
	return err
}

func (d *MySQLDepot) GetSecret(challenge string) (SecretInfo, error) {
	var secret SecretInfo
	rows, err := d.db.Query("SELECT secret, target, type, pending_period FROM secrets WHERE challenge = ?", challenge)
	if err != nil {
		return secret, err
	}
	defer rows.Close()
	if !rows.Next() {
		return secret, nil
	}
	err = rows.Scan(&secret.Secret, &secret.Target, &secret.Type, &secret.Pending_Period)
	return secret, err
}
