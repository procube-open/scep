package mysql

import (
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

type certForJSON struct {
	Id        int     `json:"id"`
	CN        string  `json:"cn"`
	Serial    big.Int `json:"serial"`
	CertData  string  `json:"cert_data"`
	Status    string  `json:"status"`
	ValidFrom string  `json:"valid_from"`
	ValidTill string  `json:"valid_till"`
}

func (d *MySQLDepot) GetRCs() ([]pkix.RevokedCertificate, error) {
	var rc pkix.RevokedCertificate
	var rcs []pkix.RevokedCertificate
	rows, err := d.db.Query("SELECT serial, revocation_date FROM certificates WHERE status = ?", "R")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var serialStr string
		var revocationTimeRaw []byte
		if err := rows.Scan(&serialStr, &revocationTimeRaw); err != nil {
			return nil, err
		}
		serial := new(big.Int)
		serial.SetString(serialStr, 16)
		revocationTimeStr := string(revocationTimeRaw)
		revocation_time, err := time.Parse("2006-01-02 15:04:05", revocationTimeStr)
		if err != nil {
			return nil, err
		}
		rc.SerialNumber = serial
		rc.RevocationTime = revocation_time
		rcs = append(rcs, rc)
	}
	return rcs, nil
}

func (d *MySQLDepot) GetCertsByCN(cn string) ([]certForJSON, error) {
	var certs []certForJSON
	rows, err := d.db.Query("SELECT id, cn, serial, cert_data, status, valid_from, valid_till FROM certificates WHERE cn = ?", cn)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c certForJSON
		var serialStr string
		var validFromRaw []byte
		var validTillRaw []byte
		var certRaw []byte
		err := rows.Scan(
			&c.Id,
			&c.CN,
			&serialStr,
			&certRaw,
			&c.Status,
			&validFromRaw,
			&validTillRaw,
		)
		if err != nil {
			return nil, err
		}
		pemBlock := &pem.Block{
			Type:  "CERTIFICATE",
			Bytes: certRaw,
		}
		pemBytes := pem.EncodeToMemory(pemBlock)
		if pemBytes != nil {
			c.CertData = string(pemBytes)
		}
		c.Serial.SetString(serialStr, 16)
		c.ValidFrom = string(validFromRaw)
		c.ValidTill = string(validTillRaw)
		certs = append(certs, c)
	}

	if err = rows.Err(); err != nil {
		return nil, err
	}
	return certs, nil
}
