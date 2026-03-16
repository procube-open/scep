package main

import (
	"context"
	"crypto"
	_ "crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"flag"
	"fmt"
	stdlog "log"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	scepclient "github.com/procube-open/scep/client"
	"github.com/procube-open/scep/scep"
	scepserver "github.com/procube-open/scep/server"

	"github.com/go-kit/kit/log"
	"github.com/go-kit/kit/log/level"
	"github.com/pkg/errors"
)

// version info
var (
	version         = "unknown"
	flVersion       = false
	flServerURL     = "http://127.0.0.1:3000/scep"
	flPKeyFileName  = "key.pem"
	flCertFileName  = "cert.pem"
	flKeySize       = "2048"
	flOrg           = "Procube"
	flOU            = ""
	flLoc           = ""
	flProvince      = ""
	flCountry       = "JP"
	flCACertMessage = ""
	flDNSName       = ""
	flAttestation   = ""

	// in case of multiple certificate authorities, we need to figure out who the recipient of the encrypted
	// data is.
	flCAFingerprint = ""

	flDebugLogging = false
	flLogJSON      = false
)

const fingerprintHashType = crypto.SHA256

type runCfg struct {
	dir             string
	csrPath         string
	keyPath         string
	keyProvider     string
	keyName         string
	publicKeySPKI   string
	keyBits         int
	selfSignPath    string
	certPath        string
	cn              string
	org             string
	ou              string
	locality        string
	province        string
	country         string
	challenge       string
	serverURL       string
	caCertsSelector scep.CertsSelector
	debug           bool
	logfmt          string
	caCertMsg       string
	dnsName         string
	attestation     string
}

func run(cfg runCfg) error {
	ctx := context.Background()
	var logger log.Logger
	{
		if strings.ToLower(cfg.logfmt) == "json" {
			logger = log.NewJSONLogger(os.Stderr)
		} else {
			logger = log.NewLogfmtLogger(os.Stderr)
		}
		stdlog.SetOutput(log.NewStdlibAdapter(logger))
		logger = log.With(logger, "ts", log.DefaultTimestampUTC)
		if !cfg.debug {
			logger = level.NewFilter(logger, level.AllowInfo())
		}
	}
	lginfo := level.Info(logger)

	client, err := scepclient.New(cfg.serverURL, logger)
	if err != nil {
		return err
	}

	key, cleanup, err := loadKeyMaterial(cfg)
	if err != nil {
		return err
	}
	defer cleanup()

	opts := &csrOptions{
		cn:        cfg.cn,
		org:       cfg.org,
		country:   strings.ToUpper(cfg.country),
		ou:        cfg.ou,
		locality:  cfg.locality,
		province:  cfg.province,
		challenge: cfg.challenge,
		key:       key,
		dnsName:   cfg.dnsName,
	}

	var csr *x509.CertificateRequest
	if cfg.keyProvider != "" {
		csr, err = makeCSR(opts)
	} else {
		csr, err = loadOrMakeCSR(cfg.csrPath, opts)
	}
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	var self *x509.Certificate
	cert, err := loadPEMCertFromFile(cfg.certPath)
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		var s *x509.Certificate
		if cfg.keyProvider != "" {
			s, err = selfSign(key, csr)
		} else {
			s, err = loadOrSign(cfg.selfSignPath, key, csr)
		}
		if err != nil {
			return err
		}
		self = s
	}

	resp, certNum, err := client.GetCACert(ctx, cfg.caCertMsg)
	if err != nil {
		return err
	}
	var certs []*x509.Certificate
	{
		if certNum > 1 {
			certs, err = scep.CACerts(resp)
			if err != nil {
				return err
			}
		} else {
			certs, err = x509.ParseCertificates(resp)
			if err != nil {
				return err
			}
		}
	}

	if cfg.debug {
		logCerts(level.Debug(logger), certs)
	}

	var signerCert *x509.Certificate
	{
		if cert != nil {
			signerCert = cert
		} else {
			signerCert = self
		}
	}

	var msgType scep.MessageType
	{
		// TODO validate CA and set UpdateReq if needed
		if cert != nil {
			msgType = scep.RenewalReq
		} else {
			msgType = scep.PKCSReq
		}
	}

	tmpl := &scep.PKIMessage{
		MessageType: msgType,
		Recipients:  certs,
		SignerKey:   key,
		SignerCert:  signerCert,
	}

	if cfg.challenge != "" && msgType == scep.PKCSReq {
		tmpl.CSRReqMessage = &scep.CSRReqMessage{
			ChallengePassword: cfg.challenge,
		}
	}

	msg, err := scep.NewCSRRequest(csr, tmpl, scep.WithLogger(logger), scep.WithCertsSelector(cfg.caCertsSelector))
	if err != nil {
		return errors.Wrap(err, "creating csr pkiMessage")
	}

	var respMsg *scep.PKIMessage

	for {
		// loop in case we get a PENDING response which requires
		// a manual approval.
		reqCtx := ctx
		if cfg.attestation != "" {
			reqCtx = scepserver.ContextWithAttestation(reqCtx, cfg.attestation)
		}

		respBytes, err := client.PKIOperation(reqCtx, msg.Raw)
		if err != nil {
			return errors.Wrapf(err, "PKIOperation for %s", msgType)
		}

		respMsg, err = scep.ParsePKIMessage(respBytes, scep.WithLogger(logger), scep.WithCACerts(msg.Recipients))
		if err != nil {
			return errors.Wrapf(err, "parsing pkiMessage response %s", msgType)
		}

		switch respMsg.PKIStatus {
		case scep.FAILURE:
			return errors.Errorf("%s request failed, failInfo: %s", msgType, respMsg.FailInfo)
		case scep.PENDING:
			lginfo.Log("pkiStatus", "PENDING", "msg", "sleeping for 30 seconds, then trying again.")
			time.Sleep(30 * time.Second)
			continue
		}
		lginfo.Log("pkiStatus", "SUCCESS", "msg", "server returned a certificate.")
		break // on scep.SUCCESS
	}

	if err := respMsg.DecryptPKIEnvelope(signerCert, key); err != nil {
		return errors.Wrapf(err, "decrypt pkiEnvelope, msgType: %s, status %s", msgType, respMsg.PKIStatus)
	}

	respCert := respMsg.CertRepMessage.Certificate
	if err := os.WriteFile(cfg.certPath, pemCert(respCert.Raw), 0666); err != nil {
		return err
	}

	// remove self signer if used
	if self != nil && cfg.keyProvider == "" {
		if err := os.Remove(cfg.selfSignPath); err != nil {
			return err
		}
	}

	return nil
}

// logCerts logs the count, number, RDN, and fingerprint of certs to logger
func logCerts(logger log.Logger, certs []*x509.Certificate) {
	logger.Log("msg", "cacertlist", "count", len(certs))
	for i, cert := range certs {
		h := fingerprintHashType.New()
		h.Write(cert.Raw)
		logger.Log(
			"msg", "cacertlist",
			"number", i,
			"rdn", cert.Subject.ToRDNSequence().String(),
			"hash_type", fingerprintHashType.String(),
			"hash", fmt.Sprintf("%x", h.Sum(nil)),
		)
	}
}

// validateFingerprint makes sure fingerprint looks like a hash.
// We remove spaces and colons from fingerprint as it may come in various forms:
//
//	e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
//	E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855
//	e3b0c442 98fc1c14 9afbf4c8 996fb924 27ae41e4 649b934c a495991b 7852b855
//	e3:b0:c4:42:98:fc:1c:14:9a:fb:f4:c8:99:6f:b9:24:27:ae:41:e4:64:9b:93:4c:a4:95:99:1b:78:52:b8:55
func validateFingerprint(fingerprint string) (hash []byte, err error) {
	fingerprint = strings.NewReplacer(" ", "", ":", "").Replace(fingerprint)
	hash, err = hex.DecodeString(fingerprint)
	if err != nil {
		return
	}
	if len(hash) != fingerprintHashType.Size() {
		err = fmt.Errorf("invalid %s hash length", fingerprintHashType)
	}
	return
}

func validateFlags(serverURL string) error {
	if serverURL == "" {
		return errors.New("must specify server-url flag parameter")
	}
	_, err := url.Parse(serverURL)
	if err != nil {
		return fmt.Errorf("invalid server-url flag parameter %s", err)
	}
	return nil
}

func validateFileKeyFlags(keyPath string) error {
	if keyPath == "" {
		return errors.New("must specify private key path")
	}
	return nil
}

func main() {
	var (
		flUid             = flag.String("uid", "", "uid of user")
		flSecret          = flag.String("secret", "", "password of user")
		flWorkDir         = flag.String("out", ".", "create certificates under this directory")
		flServerURLFlag   = flag.String("server-url", flServerURL, "SCEP server URL")
		flAttestationFlag = flag.String("attestation", flAttestation, "base64url-encoded attestation payload")
		flKeyProvider     = flag.String("key-provider", "", "Windows key storage provider name")
		flKeyName         = flag.String("key-name", "", "Windows persisted key name")
		flPublicKeySPKI   = flag.String("public-key-spki-b64", "", "base64url-encoded SubjectPublicKeyInfo for a Windows persisted key")
	)
	flag.Parse()

	// print version information
	if flVersion {
		fmt.Println(version)
		os.Exit(0)
	}

	var challenge string
	if *flUid == "" || *flSecret == "" {
		fmt.Fprintln(os.Stderr, "please set -uid and -secret option")
		os.Exit(1)
	}

	challenge = *flUid + "\\" + *flSecret
	dir := filepath.Dir(*flWorkDir)
	keyPath := filepath.Join(dir, flPKeyFileName)
	certPath := filepath.Join(dir, flCertFileName)
	csrPath := filepath.Join(dir, "csr.pem")
	selfSignPath := filepath.Join(dir, "self.pem")

	var logfmt string
	if flLogJSON {
		logfmt = "json"
	}

	keySize, _ := strconv.Atoi(flKeySize)

	if err := validateFlags(*flServerURLFlag); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	if *flKeyProvider != "" || *flKeyName != "" || *flPublicKeySPKI != "" {
		if *flKeyProvider == "" || *flKeyName == "" || *flPublicKeySPKI == "" {
			fmt.Println("please set -key-provider, -key-name, and -public-key-spki-b64 together")
			os.Exit(1)
		}
	} else if err := validateFileKeyFlags(keyPath); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	caCertsSelector := scep.NopCertsSelector()
	if flCAFingerprint != "" {
		hash, err := validateFingerprint(flCAFingerprint)
		if err != nil {
			fmt.Printf("invalid fingerprint: %s\n", err)
			os.Exit(1)
		}
		caCertsSelector = scep.FingerprintCertsSelector(fingerprintHashType, hash)
	}

	cfg := runCfg{
		dir:             dir,
		csrPath:         csrPath,
		keyPath:         keyPath,
		keyProvider:     *flKeyProvider,
		keyName:         *flKeyName,
		publicKeySPKI:   *flPublicKeySPKI,
		keyBits:         keySize,
		selfSignPath:    selfSignPath,
		certPath:        certPath,
		cn:              *flUid,
		org:             flOrg,
		country:         flCountry,
		locality:        flLoc,
		ou:              flOU,
		province:        flProvince,
		challenge:       challenge,
		serverURL:       *flServerURLFlag,
		caCertsSelector: caCertsSelector,
		debug:           flDebugLogging,
		logfmt:          logfmt,
		caCertMsg:       flCACertMessage,
		dnsName:         flDNSName,
		attestation:     *flAttestationFlag,
	}

	if err := run(cfg); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

type keyMaterial interface {
	crypto.Signer
	crypto.Decrypter
}

func loadKeyMaterial(cfg runCfg) (keyMaterial, func(), error) {
	if cfg.keyProvider != "" {
		key, err := openWindowsNCryptKey(cfg.keyProvider, cfg.keyName, cfg.publicKeySPKI)
		if err != nil {
			return nil, func() {}, err
		}
		return key, func() { _ = key.Close() }, nil
	}

	key, err := loadOrMakeKey(cfg.keyPath, cfg.keyBits)
	if err != nil {
		return nil, func() {}, err
	}
	return key, func() {}, nil
}
