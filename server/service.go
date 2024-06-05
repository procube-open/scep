package scepserver

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/procube-open/scep/depot/mysql"
	"github.com/procube-open/scep/scep"

	"github.com/go-kit/kit/log"
	"software.sslmate.com/src/go-pkcs12"
)

// Service is the interface for all supported SCEP server operations.
type Service interface {
	// GetCACaps returns a list of options
	// which are supported by the server.
	GetCACaps(ctx context.Context) ([]byte, error)

	// GetCACert returns CA certificate or
	// a CA certificate chain with intermediates
	// in a PKCS#7 Degenerate Certificates format
	// message is an optional string for the CA
	GetCACert(ctx context.Context, message string) ([]byte, int, error)

	// PKIOperation handles incoming SCEP messages such as PKCSReq and
	// sends back a CertRep PKIMessag.
	PKIOperation(ctx context.Context, msg []byte) ([]byte, error)

	// GetNextCACert returns a replacement certificate or certificate chain
	// when the old one expires. The response format is a PKCS#7 Degenerate
	// Certificates type.
	GetNextCACert(ctx context.Context) ([]byte, error)

	GetCRL(ctx context.Context, depotPath string, message string) ([]byte, error)

	CreatePKCS12(ctx context.Context, depotPath string, msg []byte) ([]byte, error)
}

type createInfo *struct {
	Uid      string `json:"uid"`
	Secret   string `json:"secret"`
	Password string `json:"password"`
}

type service struct {
	// The service certificate and key for SCEP exchanges. These are
	// quite likely the same as the CA keypair but may be its own SCEP
	// specific keypair in the case of e.g. RA (proxy) operation.
	crt *x509.Certificate
	key *rsa.PrivateKey

	// Optional additional CA certificates for e.g. RA (proxy) use.
	// Only used in this service when responding to GetCACert.
	addlCa []*x509.Certificate

	// The (chainable) CSR signing function. Intended to handle all
	// SCEP request functionality such as CSR & challenge checking, CA
	// issuance, RA proxying, etc.
	signer CSRSignerContext

	/// info logging is implemented in the service middleware layer.
	debugLogger log.Logger
}

func (svc *service) GetCACaps(ctx context.Context) ([]byte, error) {
	defaultCaps := []byte("Renewal\nSHA-1\nSHA-256\nAES\nDES3\nSCEPStandard\nPOSTPKIOperation")
	return defaultCaps, nil
}

func (svc *service) GetCACert(ctx context.Context, _ string) ([]byte, int, error) {
	if svc.crt == nil {
		return nil, 0, errors.New("missing CA certificate")
	}
	if len(svc.addlCa) < 1 {
		return svc.crt.Raw, 1, nil
	}
	certs := []*x509.Certificate{svc.crt}
	certs = append(certs, svc.addlCa...)
	data, err := scep.DegenerateCertificates(certs)
	return data, len(svc.addlCa) + 1, err
}

func (svc *service) PKIOperation(ctx context.Context, data []byte) ([]byte, error) {
	msg, err := scep.ParsePKIMessage(data, scep.WithLogger(svc.debugLogger))
	if err != nil {
		return nil, err
	}
	if err := msg.DecryptPKIEnvelope(svc.crt, svc.key); err != nil {
		return nil, err
	}

	crt, err := svc.signer.SignCSRContext(ctx, msg.CSRReqMessage)
	if err == nil && crt == nil {
		err = errors.New("no signed certificate")
	}
	if err != nil {
		svc.debugLogger.Log("msg", "failed to sign CSR", "err", err)
		certRep, err := msg.Fail(svc.crt, svc.key, scep.BadRequest)
		return certRep.Raw, err
	}

	certRep, err := msg.Success(svc.crt, svc.key, crt)
	return certRep.Raw, err
}

func (svc *service) GetNextCACert(ctx context.Context) ([]byte, error) {
	panic("not implemented")
}

type distributionPointName struct {
	FullName     []asn1.RawValue  `asn1:"optional,tag:0"`
	RelativeName pkix.RDNSequence `asn1:"optional,tag:1"`
}
type issuingDistributionPoint struct {
	DistributionPoint          distributionPointName `asn1:"optional,tag:0"`
	OnlyContainsUserCerts      bool                  `asn1:"optional,tag:1"`
	OnlyContainsCACerts        bool                  `asn1:"optional,tag:2"`
	OnlySomeReasons            asn1.BitString        `asn1:"optional,tag:3"`
	IndirectCRL                bool                  `asn1:"optional,tag:4"`
	OnlyContainsAttributeCerts bool                  `asn1:"optional,tag:5"`
}

var oidExtensionIssuingDistributionPoint = []int{2, 5, 29, 28}

func (svc *service) GetCRL(ctx context.Context, depotPath string, _ string) ([]byte, error) {
	dsn := envString("SCEP_DSN", "")
	port := envString("SCEP_HTTP_LISTEN_PORT", "")
	caPass := envString("SCEP_CA_PASS", "")
	depot, err := mysql.NewTableDepot(dsn, depotPath)
	if err != nil {
		return nil, err
	}
	rcs, err := depot.GetRCs()
	if err != nil {
		return nil, err
	}

	cert, key, err := depot.CA([]byte(caPass))
	if err != nil {
		return nil, err
	}

	dp := distributionPointName{
		FullName: []asn1.RawValue{
			{Tag: 6, Class: 2, Bytes: []byte("http://localhost:" + port + "/scep?operation=GetCRL")},
		},
	}
	idp := issuingDistributionPoint{
		DistributionPoint: dp,
	}

	v, err := asn1.Marshal(idp)
	if err != nil {
		return nil, err
	}

	cdpExt := pkix.Extension{
		Id:       oidExtensionIssuingDistributionPoint,
		Critical: true,
		Value:    v,
	}

	crlTpl := &x509.RevocationList{
		SignatureAlgorithm:  x509.SHA256WithRSA,
		RevokedCertificates: rcs,
		Number:              big.NewInt(2),
		ThisUpdate:          time.Now(),
		NextUpdate:          time.Now().Add(24 * time.Hour),
		ExtraExtensions:     []pkix.Extension{cdpExt},
	}

	crl, err := x509.CreateRevocationList(rand.Reader, crlTpl, cert[0], key)
	if err != nil {
		return nil, err
	}
	return crl, nil
}

func (svc *service) CreatePKCS12(ctx context.Context, depotPath string, msg []byte) ([]byte, error) {
	var info createInfo
	var err error
	if err := json.Unmarshal(msg, &info); err != nil {
		return nil, err
	}
	if info.Password == "" {
		return nil, errors.New("cannot set empty password")
	}
	if info.Uid != "" && info.Secret != "" {
		os.RemoveAll("/tmp/" + info.Uid)
		if err := os.Mkdir("/tmp/"+info.Uid, 0770); err != nil {
			return nil, err
		}
		// cert.pem,key.pem,csr.pemを作成
		fmt.Println("--- POST CSR myself ---")
		cmd := exec.Command("./scepclient-opt", "-uid", info.Uid, "-secret", info.Secret, "-out", "/tmp/"+info.Uid+"/")
		var out strings.Builder
		cmd.Stdout = &out
		err = cmd.Run()
		fmt.Println(out.String())
	} else {
		err = errors.New("without uid or secret params")
	}
	fmt.Println("--- finish ---")
	if err != nil {
		return nil, errors.New("failed to verify CSR")
	}
	// pkcs12形式に変換
	//X509.PrivateKey読み込み
	key, err := os.ReadFile("/tmp/" + info.Uid + "/key.pem")
	if err != nil {
		return nil, err
	}
	keyBlock, _ := pem.Decode([]byte(key))
	k, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, err
	}

	//X509.Certificate読み込み
	cert, err := os.ReadFile("/tmp/" + info.Uid + "/cert.pem")
	if err != nil {
		return nil, err
	}
	certBlock, _ := pem.Decode([]byte(cert))
	c, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, err
	}

	//X509.Certificate読み込み
	caCert, err := os.ReadFile(depotPath + "/ca.crt")
	if err != nil {
		return nil, err
	}
	caCertBlock, _ := pem.Decode([]byte(caCert))
	ca, err := x509.ParseCertificate(caCertBlock.Bytes)
	if err != nil {
		return nil, err
	}
	var caCerts []*x509.Certificate
	caCerts = append(caCerts, ca)

	//PKCS12エンコード
	p12, err := pkcs12.LegacyDES.Encode(k, c, caCerts, info.Password)
	if err != nil {
		return nil, err
	}

	//ファイルを掃除
	os.RemoveAll("/tmp/" + info.Uid)

	return p12, nil
}

// ServiceOption is a server configuration option
type ServiceOption func(*service) error

// WithLogger configures a logger for the SCEP Service.
// By default, a no-op logger is used.
func WithLogger(logger log.Logger) ServiceOption {
	return func(s *service) error {
		s.debugLogger = logger
		return nil
	}
}

// WithAddlCA appends an additional certificate to the slice of CA certs
func WithAddlCA(ca *x509.Certificate) ServiceOption {
	return func(s *service) error {
		s.addlCa = append(s.addlCa, ca)
		return nil
	}
}

// NewService creates a new scep service
func NewService(crt *x509.Certificate, key *rsa.PrivateKey, signer CSRSignerContext, opts ...ServiceOption) (Service, error) {
	s := &service{
		crt:         crt,
		key:         key,
		signer:      signer,
		debugLogger: log.NewNopLogger(),
	}
	for _, opt := range opts {
		if err := opt(s); err != nil {
			return nil, err
		}
	}
	return s, nil
}
