package mysql

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

type MySQLDepot struct {
	db      *sql.DB
	dirPath string
}

func NewTableDepot(dsn, dirPath string) (*MySQLDepot, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	if err = db.Ping(); err != nil {
		return nil, err
	}

	// Create table if not exists
	createClientsTableQuery := `
	CREATE TABLE IF NOT EXISTS clients (
		uid VARCHAR(255) NOT NULL PRIMARY KEY,
		status VARCHAR(255) NOT NULL,
		attributes TEXT DEFAULT NULL
	);`
	createCertsTableQuery := `
	CREATE TABLE IF NOT EXISTS certificates (
		id INT AUTO_INCREMENT PRIMARY KEY,
		cn VARCHAR(255) NOT NULL,
		serial VARCHAR(255) NOT NULL,
		cert_data BLOB NOT NULL,
		status CHAR(1) NOT NULL,
		valid_from TIMESTAMP NOT NULL,
		valid_till TIMESTAMP NOT NULL,
		revocation_date TIMESTAMP DEFAULT NULL
	);`
	createSerialTableQuery := `
	CREATE TABLE IF NOT EXISTS serial_table (
		id INT AUTO_INCREMENT PRIMARY KEY,
		serial VARCHAR(255) NOT NULL
	);`
	createSecretsTableQuery := `
	CREATE TABLE IF NOT EXISTS secrets (
		challenge VARCHAR(255) NOT NULL PRIMARY KEY,
		secret VARCHAR(255) NOT NULL,
		target VARCHAR(255) NOT NULL,
		type VARCHAR(255) NOT NULL,
		created_at TIMESTAMP NOT NULL,
		delete_at TIMESTAMP NOT NULL,
		pending_period VARCHAR(255) DEFAULT NULL,
		FOREIGN KEY (target) REFERENCES clients(uid)
	);`

	_, err = db.Exec(createClientsTableQuery)
	if err != nil {
		return nil, err
	}
	_, err = db.Exec(createCertsTableQuery)
	if err != nil {
		return nil, err
	}
	_, err = db.Exec(createSerialTableQuery)
	if err != nil {
		return nil, err
	}

	_, err = db.Exec(createSecretsTableQuery)
	if err != nil {
		return nil, err
	}

	return &MySQLDepot{db: db, dirPath: dirPath}, nil
}

func (d *MySQLDepot) CA(pass []byte) ([]*x509.Certificate, *rsa.PrivateKey, error) {
	caPEM, err := d.GetFile("ca.crt")
	if err != nil {
		return nil, nil, err
	}
	cert, err := loadCert(caPEM.Data)
	if err != nil {
		return nil, nil, err
	}
	keyPEM, err := d.GetFile("ca.key")
	if err != nil {
		return nil, nil, err
	}
	key, err := loadKey(keyPEM.Data, pass)
	if err != nil {
		return nil, nil, err
	}
	return []*x509.Certificate{cert}, key, nil
}

func (d *MySQLDepot) Put(cn string, crt *x509.Certificate, challenge string) error {
	serial := crt.SerialNumber
	if crt.Subject.CommonName == "" {
		cn = fmt.Sprintf("%x", sha256.Sum256(crt.Raw))
	}

	if err := d.writeDB(cn, serial, challenge, crt); err != nil {
		return err
	}

	return nil
}

func (d *MySQLDepot) Serial() (*big.Int, error) {
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
	if err := d.incrementSerial(serial); err != nil {
		return serial, err
	}
	return serial, nil
}

func (d *MySQLDepot) HasCN(cn string, allowTime int, cert *x509.Certificate, revokeOldCertificate bool) (bool, error) {
	rows, err := d.db.Query("SELECT id, status, valid_from FROM certificates WHERE cn = ?", cn)
	if err != nil {
		return false, err
	}
	defer rows.Close()

	var candidates = make(map[string]string)
	for rows.Next() {
		var id int
		var status string
		var validFrom time.Time
		if err := rows.Scan(&id, &status, &validFrom); err != nil {
			return false, err
		}

		serial := fmt.Sprintf("%x", cert.SerialNumber)
		if status == "R" {
			candidates[serial] = fmt.Sprintf("%d", id)
			delete(candidates, serial)
		} else if status == "V" {
			if validFrom.After(time.Now().AddDate(0, 0, allowTime)) && allowTime > 0 {
				candidates[serial] = "no"
			} else {
				candidates[serial] = fmt.Sprintf("%d", id)
			}
		}
	}
	for _, value := range candidates {
		if value == "no" {
			return false, errors.New("CN " + cn + " already exists")
		}
		if revokeOldCertificate {
			id, err := strconv.Atoi(value)
			if err != nil {
				return false, err
			}
			_, err = d.db.Exec("UPDATE certificates SET status = 'R', revocation_date = ? WHERE id = ?", time.Now(), id)
			if err != nil {
				return false, err
			}
		}
	}
	return true, nil
}

func (d *MySQLDepot) writeDB(cn string, serial *big.Int, challenge string, cert *x509.Certificate) error {
	client, err := d.GetClient(cn)
	if err != nil {
		return err
	}
	if client.Status == "ISSUABLE" {
		if _, err := d.HasCN(cn, 0, cert, true); err != nil {
			return err
		}
		if err := d.UpdateStatusClient(cn, "ISSUED"); err != nil {
			return err
		}
	} else if client.Status == "UPDATABLE" {
		if _, err := d.HasCN(cn, 0, cert, false); err != nil {
			return err
		}
		if err := d.UpdateStatusClient(cn, "PENDING"); err != nil {
			return err
		}
		secret, err := d.GetSecret(challenge)
		if err != nil {
			return err
		}
		duration, err := time.ParseDuration(secret.Pending_Period)
		if err != nil {
			return err
		}
		revocation_date := time.Now().Add(duration)
		_, err = d.db.Exec("UPDATE certificates SET revocation_date = ? WHERE cn = ? AND status = 'V'", revocation_date, cn)
		if err != nil {
			return err
		}
	} else {
		return errors.New("client is not issuable or updatable")
	}

	notBefore := cert.NotBefore
	notAfter := cert.NotAfter

	serialStr := fmt.Sprintf("%x", serial) // Convert serial to string
	_, err = d.db.Exec("INSERT INTO certificates (cn, serial, cert_data, status, valid_from, valid_till) VALUES (?, ?, ?, ?, ?, ?)",
		cn, serialStr, cert.Raw, "V", notBefore, notAfter)
	if err != nil {
		return err
	}
	if err := d.DeleteSecret(challenge); err != nil {
		return err
	}
	return nil
}

func (d *MySQLDepot) writeSerial(serial *big.Int) error {
	serialStr := fmt.Sprintf("%x", serial.Bytes())
	var rowExists int
	err := d.db.QueryRow("SELECT COUNT(*) FROM serial_table").Scan(&rowExists)
	if err != nil {
		return err
	}
	if rowExists > 0 {
		_, err = d.db.Exec("UPDATE serial_table SET serial = ? ORDER BY id LIMIT 1", serialStr)
		if err != nil {
			return err
		}
	} else {
		_, err = d.db.Exec("INSERT INTO serial_table (serial) VALUES (?)", serialStr)
		if err != nil {
			return err
		}
	}
	return nil
}

func (d *MySQLDepot) incrementSerial(s *big.Int) error {
	serial := s.Add(s, big.NewInt(1))
	if err := d.writeSerial(serial); err != nil {
		return err
	}
	return nil
}

// Load an encrypted private key from disk
func loadKey(data []byte, password []byte) (*rsa.PrivateKey, error) {
	pemBlock, _ := pem.Decode(data)
	if pemBlock == nil {
		return nil, errors.New("PEM decode failed")
	}

	if x509.IsEncryptedPEMBlock(pemBlock) {
		b, err := x509.DecryptPEMBlock(pemBlock, password)
		if err != nil {
			return nil, err
		}
		return x509.ParsePKCS1PrivateKey(b)
	}
	return x509.ParsePKCS1PrivateKey(pemBlock.Bytes)
}

func loadCert(data []byte) (*x509.Certificate, error) {
	pemBlock, _ := pem.Decode(data)
	if pemBlock == nil {
		return nil, errors.New("PEM decode failed")
	}
	return x509.ParseCertificate(pemBlock.Bytes)
}

type file struct {
	Info os.FileInfo
	Data []byte
}

func (d *MySQLDepot) check(path string) error {
	name := d.path(path)
	_, err := os.Stat(name)
	if err != nil {
		return err
	}
	return nil
}

func (d *MySQLDepot) path(name string) string {
	return filepath.Join(d.dirPath, name)
}

func (d *MySQLDepot) GetFile(path string) (*file, error) {
	if err := d.check(path); err != nil {
		return nil, err
	}
	fi, err := os.Stat(d.path(path))
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(d.path(path))
	return &file{fi, b}, err
}
