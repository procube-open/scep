package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/procube-open/scep/csrverifier"
	executablecsrverifier "github.com/procube-open/scep/csrverifier/executable"
	scepdepot "github.com/procube-open/scep/depot"
	"github.com/procube-open/scep/depot/file"
	"github.com/procube-open/scep/idm"
	scepserver "github.com/procube-open/scep/server"

	"github.com/go-kit/kit/log"
	"github.com/go-kit/kit/log/level"
)

// version info
var (
	version = "unknown"
)

type issuingDistributionPoint struct {
	DistributionPoint          distributionPointName `asn1:"optional,tag:0"`
	OnlyContainsUserCerts      bool                  `asn1:"optional,tag:1"`
	OnlyContainsCACerts        bool                  `asn1:"optional,tag:2"`
	OnlySomeReasons            asn1.BitString        `asn1:"optional,tag:3"`
	IndirectCRL                bool                  `asn1:"optional,tag:4"`
	OnlyContainsAttributeCerts bool                  `asn1:"optional,tag:5"`
}

type distributionPointName struct {
	FullName     []asn1.RawValue  `asn1:"optional,tag:0"`
	RelativeName pkix.RDNSequence `asn1:"optional,tag:1"`
}

var oidExtensionIssuingDistributionPoint = []int{2, 5, 29, 28}

func main() {
	var caCMD = flag.NewFlagSet("ca", flag.ExitOnError)
	{
		if len(os.Args) >= 2 {
			if os.Args[1] == "ca" {
				status := caMain(caCMD)
				os.Exit(status)
			}
		}
	}

	//main flags
	var (
		flVersion           = flag.Bool("version", false, "prints version information")
		flHTTPAddr          = flag.String("http-addr", envString("SCEP_HTTP_ADDR", ""), "http listen address. defaults to \":8080\"")
		flPort              = flag.String("port", envString("SCEP_HTTP_LISTEN_PORT", "3000"), "http port to listen on (if you want to specify an address, use -http-addr instead)")
		flDepotPath         = flag.String("depot", envString("SCEP_FILE_DEPOT", "idm-depot"), "path to ca folder")
		flCAPass            = flag.String("capass", envString("SCEP_CA_PASS", ""), "passwd for the ca.key")
		flClDuration        = flag.String("crtvalid", envString("SCEP_CERT_VALID", "365"), "validity for new client certificates in days")
		flClAllowRenewal    = flag.String("allowrenew", envString("SCEP_CERT_RENEW", "0"), "do not allow renewal until n days before expiry, set to 0 to always allow")
		flChallengePassword = flag.String("challenge", envString("SCEP_CHALLENGE_PASSWORD", ""), "enforce a challenge password")
		flCSRVerifierExec   = flag.String("csrverifierexec", envString("SCEP_CSR_VERIFIER_EXEC", ""), "will be passed the CSRs for verification")
		flDebug             = flag.Bool("debug", envBool("SCEP_LOG_DEBUG"), "enable debug logging")
		flLogJSON           = flag.Bool("log-json", envBool("SCEP_LOG_JSON"), "output JSON logs")
		flSignServerAttrs   = flag.Bool("sign-server-attrs", envBool("SCEP_SIGN_SERVER_ATTRS"), "sign cert attrs for server usage")
		flGetURL            = flag.String("geturl", envString("SCEP_IDM_GET_URL", ""), "URL of IDManager for GET users")
		flPutURL            = flag.String("puturl", envString("SCEP_IDM_PUT_URL", ""), "URL of IDManager for PUT certs")
	)
	flag.Usage = func() {
		flag.PrintDefaults()

		fmt.Println("usage: scep [<command>] [<args>]")
		fmt.Println(" ca <args> create/manage a CA")
		fmt.Println("type <command> --help to see usage for each subcommand")
	}
	flag.Parse()

	// print version information
	if *flVersion {
		fmt.Println(version)
		os.Exit(0)
	}

	// -http-addr and -port conflict. Don't allow the user to set both.
	httpAddrSet := setByUser("http-addr", "SCEP_HTTP_ADDR")
	portSet := setByUser("port", "SCEP_HTTP_LISTEN_PORT")
	var httpAddr string
	if httpAddrSet && portSet {
		fmt.Fprintln(os.Stderr, "cannot set both -http-addr and -port")
		os.Exit(1)
	} else if httpAddrSet {
		httpAddr = *flHTTPAddr
	} else {
		httpAddr = ":" + *flPort
	}

	var logger log.Logger
	{

		if *flLogJSON {
			logger = log.NewJSONLogger(os.Stderr)
		} else {
			logger = log.NewLogfmtLogger(os.Stderr)
		}
		if !*flDebug {
			logger = level.NewFilter(logger, level.AllowInfo())
		}
		logger = log.With(logger, "ts", log.DefaultTimestampUTC)
		logger = log.With(logger, "caller", log.DefaultCaller)
	}
	lginfo := level.Info(logger)

	var err error
	var depot scepdepot.Depot // cert storage
	{
		depot, err = file.NewFileDepot(*flDepotPath)
		if err != nil {
			lginfo.Log("err", err)
			os.Exit(1)
		}
	}
	allowRenewal, err := strconv.Atoi(*flClAllowRenewal)
	if err != nil {
		lginfo.Log("err", err, "msg", "No valid number for allowed renewal time")
		os.Exit(1)
	}
	clientValidity, err := strconv.Atoi(*flClDuration)
	if err != nil {
		lginfo.Log("err", err, "msg", "No valid number for client cert validity")
		os.Exit(1)
	}
	var csrVerifier csrverifier.CSRVerifier
	if *flCSRVerifierExec > "" {
		executableCSRVerifier, err := executablecsrverifier.New(*flCSRVerifierExec, lginfo)
		if err != nil {
			lginfo.Log("err", err, "msg", "Could not instantiate CSR verifier")
			os.Exit(1)
		}
		csrVerifier = executableCSRVerifier
	}

	var svc scepserver.Service // scep service
	{
		crts, key, err := depot.CA([]byte(*flCAPass))
		if err != nil {
			lginfo.Log("err", err)
			os.Exit(1)
		}
		if len(crts) < 1 {
			lginfo.Log("err", "missing CA certificate")
			os.Exit(1)
		}
		signerOpts := []scepdepot.Option{
			scepdepot.WithAllowRenewalDays(allowRenewal),
			scepdepot.WithValidityDays(clientValidity),
			scepdepot.WithCAPass(*flCAPass),
		}
		if *flSignServerAttrs {
			signerOpts = append(signerOpts, scepdepot.WithSeverAttrs())
		}

		var getUrl string
		if *flGetURL != "" {
			getUrl = *flGetURL
		}

		var putUrl string
		if *flPutURL != "" {
			putUrl = *flPutURL
		}

		var signer scepserver.CSRSignerContext = scepserver.SignCSRAdapter(scepdepot.NewSigner(depot, signerOpts...), putUrl)
		if *flChallengePassword != "" {
			signer = scepserver.StaticChallengeMiddleware(*flChallengePassword, signer)
		}
		if getUrl != "" {
			signer = scepserver.IDMChallengeMiddleware(getUrl, signer)
		}
		if csrVerifier != nil {
			signer = csrverifier.Middleware(csrVerifier, signer)
		}
		svc, err = scepserver.NewService(crts[0], key, signer, scepserver.WithLogger(logger))
		if err != nil {
			lginfo.Log("err", err)
			os.Exit(1)
		}
		svc = scepserver.NewLoggingService(log.With(lginfo, "component", "scep_service"), svc)
	}

	var h http.Handler // http handler
	{
		e := scepserver.MakeServerEndpoints(svc, *flDepotPath)
		e.GetEndpoint = scepserver.EndpointLoggingMiddleware(lginfo)(e.GetEndpoint)
		e.PostEndpoint = scepserver.EndpointLoggingMiddleware(lginfo)(e.PostEndpoint)
		h = scepserver.MakeHTTPHandler(e, svc, log.With(lginfo, "component", "http"))
	}

	// start http server
	errs := make(chan error, 2)
	go func() {
		lginfo.Log("transport", "http", "address", httpAddr, "msg", "listening")
		errs <- http.ListenAndServe(httpAddr, h)
	}()
	go func() {
		c := make(chan os.Signal)
		signal.Notify(c, syscall.SIGINT)
		errs <- fmt.Errorf("%s", <-c)
	}()

	lginfo.Log("terminated", <-errs)
}

func caMain(cmd *flag.FlagSet) int {
	var (
		flDepotPath  = cmd.String("depot", envString("SCEP_FILE_DEPOT", "idm-depot"), "path to ca folder")
		flInit       = cmd.Bool("init", false, "create a new CA")
		flCreateCRL  = cmd.Bool("create-crl", false, "create a new CRL")
		flPort       = flag.String("port", envString("SCEP_HTTP_LISTEN_PORT", "3000"), "http port to listen on (if you want to specify an address, use -http-addr instead)")
		flCRLURL     = cmd.String("crlurl", envString("SCEPCA_IDM_CRL_URL", ""), "URL of IDManager")
		flYears      = cmd.Int("years", envInt("SCEPCA_YEARS", 10), "default CA years")
		flKeySize    = cmd.Int("keySize", envInt("SCEPCA_KEY_SIZE", 4096), "rsa key size")
		flCommonName = cmd.String("common_name", envString("SCEPCA_CN", "Procube SCEP CA"), "common name (CN) for CA cert")
		flOrg        = cmd.String("organization", envString("SCEPCA_ORG", "Procube"), "organization for CA cert")
		flOrgUnit    = cmd.String("organizational_unit", envString("SCEPCA_ORG_UNIT", ""), "organizational unit (OU) for CA cert")
		flPassword   = cmd.String("key-password", "", "password to store rsa key")
		flCAPass     = flag.String("capass", envString("SCEP_CA_PASS", ""), "passwd for the ca.key")
		flCountry    = cmd.String("country", envString("SCEPCA_COUNTRY", "JP"), "country for CA cert")
	)
	cmd.Parse(os.Args[2:])
	if *flInit {
		fmt.Println("Initializing new CA")
		key, err := createKey(*flKeySize, []byte(*flPassword), *flDepotPath)
		if err != nil {
			fmt.Println(err)
			return 0
		}
		if err := createCertificateAuthority(key, *flYears, *flCommonName, *flOrg, *flOrgUnit, *flCountry, *flDepotPath); err != nil {
			fmt.Println(err)
			return 0
		}
	} else if *flCreateCRL {
		fmt.Println("Creating new CRL file")
		var err error
		var depot scepdepot.Depot // cert storage
		{
			depot, err = file.NewFileDepot(*flDepotPath)
			if err != nil {
				os.Exit(1)
			}
		}
		crts, key, _ := depot.CA([]byte(*flCAPass))
		CreateCRL(crts[0], key, *flDepotPath, *flCRLURL, *flPort)
	}

	return 0
}

// create a key, save it to depot and return it for further usage.
func createKey(bits int, password []byte, depot string) (*rsa.PrivateKey, error) {
	// create depot folder if missing
	if err := os.MkdirAll(depot, 0755); err != nil {
		return nil, err
	}
	name := filepath.Join(depot, "ca.key")
	file, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0400)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	// create RSA key and save as PEM file
	key, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		return nil, err
	}
	privPEMBlock, err := x509.EncryptPEMBlock(
		rand.Reader,
		rsaPrivateKeyPEMBlockType,
		x509.MarshalPKCS1PrivateKey(key),
		password,
		x509.PEMCipher3DES,
	)
	if err != nil {
		return nil, err
	}
	if err := pem.Encode(file, privPEMBlock); err != nil {
		os.Remove(name)
		return nil, err
	}

	return key, nil
}

func createCertificateAuthority(key *rsa.PrivateKey, years int, commonName string, organization string, organizationalUnit string, country string, depot string) error {
	cert := scepdepot.NewCACert(
		scepdepot.WithYears(years),
		scepdepot.WithCommonName(commonName),
		scepdepot.WithOrganization(organization),
		scepdepot.WithOrganizationalUnit(organizationalUnit),
		scepdepot.WithCountry(country),
	)
	crtBytes, err := cert.SelfSign(rand.Reader, &key.PublicKey, key)
	if err != nil {
		return err
	}

	name := filepath.Join(depot, "ca.crt")
	file, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0400)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := file.Write(pemCert(crtBytes)); err != nil {
		file.Close()
		os.Remove(name)
		return err
	}

	return nil
}

const (
	rsaPrivateKeyPEMBlockType = "RSA PRIVATE KEY"
	certificatePEMBlockType   = "CERTIFICATE"
)

func pemCert(derBytes []byte) []byte {
	pemBlock := &pem.Block{
		Type:    certificatePEMBlockType,
		Headers: nil,
		Bytes:   derBytes,
	}
	out := pem.EncodeToMemory(pemBlock)
	return out
}

func envString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}

func envInt(key string, def int) int {
	if env := os.Getenv(key); env != "" {
		num, _ := strconv.Atoi(env)
		return num
	}
	return def
}

func envBool(key string) bool {
	if env := os.Getenv(key); env == "true" {
		return true
	}
	return false
}

func setByUser(flagName, envName string) bool {
	userDefinedFlags := make(map[string]bool)
	flag.Visit(func(f *flag.Flag) {
		userDefinedFlags[f.Name] = true
	})
	flagSet := userDefinedFlags[flagName]
	_, envSet := os.LookupEnv(envName)
	return flagSet || envSet
}

func CreateCRL(cert *x509.Certificate, key *rsa.PrivateKey, depotPath string, url string, port string) {

	rcs := GetSerialNumbers(depotPath, url)

	//Create issuingDistributionPoint Extension
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
		fmt.Printf("ERROR:%v\n", err)
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

	var derCrl []byte
	derCrl, err = x509.CreateRevocationList(rand.Reader, crlTpl, cert, key)
	if err != nil {
		fmt.Printf("ERROR:%v\n", err)
	}
	var f *os.File
	f, err = os.Create(filepath.Join(depotPath, "ca.crl"))
	if err != nil {
		fmt.Printf("ERROR:%v\n", err)
	}

	err = pem.Encode(f, &pem.Block{Type: "X509 CRL", Bytes: derCrl})
	if err != nil {
		fmt.Printf("ERROR:%v\n", err)
	}
	err = f.Close()

}

func GetSerialNumbers(depotPath string, crlUrl string) []pkix.RevokedCertificate {
	var rcs []pkix.RevokedCertificate
	var rc pkix.RevokedCertificate

	//index.txtから取得
	crlpath := filepath.Join(depotPath, "index.txt")
	fp, err := os.Open(crlpath)
	if err != nil {
		panic(err)
	}
	defer fp.Close()

	scanner := bufio.NewScanner(fp)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "R\t") {
			arr := strings.Split(line, "\t")
			serial, _ := strconv.ParseInt(arr[3], 16, 64)
			time, _ := time.Parse("060102150405Z", arr[2])
			rc = pkix.RevokedCertificate{
				SerialNumber:   big.NewInt(serial),
				RevocationTime: time,
			}
			rcs = append(rcs, rc)
		}
	}
	if err = scanner.Err(); err != nil {
		return nil
	}

	//idmから取得
	certs, err := idm.GETRCs(crlUrl)
	if err != nil {
		fmt.Println(err)
	}
	for _, cert := range certs {
		block, _ := pem.Decode([]byte(cert.Certificate))
		p, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			fmt.Println(err)
			return nil
		}
		rc = pkix.RevokedCertificate{
			SerialNumber:   p.SerialNumber,
			RevocationTime: time.Now(),
		}
		rcs = append(rcs, rc)
	}

	return rcs
}
