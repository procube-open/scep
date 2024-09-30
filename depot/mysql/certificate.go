package mysql

import (
	"crypto/x509/pkix"
	"database/sql"
	"encoding/pem"
	"math/big"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

type certForJSON struct {
	Id             int       `json:"id"`
	CN             string    `json:"cn"`
	Serial         big.Int   `json:"serial"`
	CertData       string    `json:"cert_data"`
	Status         string    `json:"status"`
	ValidFrom      time.Time `json:"valid_from"`
	ValidTill      time.Time `json:"valid_till"`
	RevocationDate time.Time `json:"revocation_date"`
}

func (d *MySQLDepot) GetRCs() ([]pkix.RevokedCertificate, error) {
	var rcs []pkix.RevokedCertificate
	rows, err := d.db.Query("SELECT serial, revocation_date FROM certificates WHERE status = ? AND valid_till > NOW()", "R")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var rc pkix.RevokedCertificate
		var serialStr string
		var revocationTime sql.NullTime
		if err := rows.Scan(&serialStr, &revocationTime); err != nil {
			return nil, err
		}
		serial := new(big.Int)
		serial.SetString(serialStr, 16)

		rc.SerialNumber = serial
		if revocationTime.Valid {
			rc.RevocationTime = revocationTime.Time
		}
		rcs = append(rcs, rc)
	}
	return rcs, nil
}

func (d *MySQLDepot) GetCertsByCN(cn string) ([]certForJSON, error) {
	var certs []certForJSON
	rows, err := d.db.Query("SELECT id, cn, serial, cert_data, status, valid_from, valid_till, revocation_date FROM certificates WHERE cn = ?", cn)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c certForJSON
		var serialStr string
		var certRaw []byte
		var revocationDate sql.NullTime
		err := rows.Scan(
			&c.Id,
			&c.CN,
			&serialStr,
			&certRaw,
			&c.Status,
			&c.ValidFrom,
			&c.ValidTill,
			&revocationDate,
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
		if revocationDate.Valid {
			c.RevocationDate = revocationDate.Time
		}
		c.Serial.SetString(serialStr, 16)
		certs = append(certs, c)
	}

	if err = rows.Err(); err != nil {
		return nil, err
	}
	return certs, nil
}

func (d *MySQLDepot) GetNextSerial() (*big.Int, error) {
	var serialStr string
	err := d.db.QueryRow("SELECT serial FROM serial_table LIMIT 1").Scan(&serialStr)
	if err == sql.ErrNoRows {
		s := big.NewInt(2)
		if err := d.writeSerial(s); err != nil {
			return nil, err
		}
		return s, nil
	} else if err != nil {
		return nil, err
	}
	serial := new(big.Int)
	serial.SetString(serialStr, 16)
	serial.Add(serial, big.NewInt(1))
	return serial, nil
}

func (d *MySQLDepot) RevokeCertificate(uid string, revocation_date time.Time) error {
	_, err := d.db.Exec("UPDATE certificates SET status = 'R', revocation_date = ? WHERE cn = ? AND status = 'V'", revocation_date, uid)
	return err
}

func (d *MySQLDepot) CheckCertRevocation() error {
	rows, err := d.db.Query("SELECT cn, id FROM certificates WHERE status = ? AND revocation_date IS NOT NULL AND revocation_date < NOW()", "V")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cn string
		var id int
		err := rows.Scan(&cn, &id)
		if err != nil {
			return err
		}
		client, err := d.GetClient(cn)
		if err != nil {
			return err
		}
		if client.Status == "PENDING" {
			_, err = d.db.Exec("UPDATE certificates SET status = 'R' WHERE id = ?", id)
			d.db.Exec("UPDATE clients SET status = 'ISSUED' WHERE uid = ?", cn)
			return err
		}
	}
	return nil
}

func (d *MySQLDepot) CheckCertExpiration() error {
	rows, err := d.db.Query("SELECT cn, id FROM certificates WHERE status = ? AND valid_till < NOW()", "V")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cn string
		var id int
		err := rows.Scan(&cn, &id)
		if err != nil {
			return err
		}
		client, err := d.GetClient(cn)
		if err != nil {
			return err
		}
		if client.Status == "ISSUED" {
			_, err = d.db.Exec("UPDATE certificates SET status = 'R' WHERE id = ?", id)
			d.db.Exec("UPDATE clients SET status = 'INACTIVE' WHERE uid = ?", cn)
			return err
		}
	}
	return nil
}
