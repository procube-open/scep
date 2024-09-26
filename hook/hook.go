package hook

import (
	"crypto/x509"
	"fmt"
	"os/exec"

	"github.com/procube-open/scep/utils"
)

func InitialHook() error {
	script := utils.EnvString("SCEP_INITIAL_SCRIPT", "")
	if script == "" {
		return nil
	}
	cmd := exec.Command(script)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return err
	}
	if string(output) != "" {
		fmt.Println(string(output))
	}
	return nil
}

func SignHook(cert *x509.Certificate) error {
	script := utils.EnvString("SCEP_SIGN_SCRIPT", "")
	timeFormat := utils.EnvString("SCEP_SCRIPT_TIME_FORMAT", "2006-01-02 15:04:05")
	if script == "" {
		return nil
	}
	notBefore := cert.NotBefore.Format(timeFormat)
	notAfter := cert.NotAfter.Format(timeFormat)
	cmd := exec.Command(script)
	cmd.Env = append(cmd.Env, "CN="+cert.Subject.CommonName)
	cmd.Env = append(cmd.Env, "NOT_BEFORE="+notBefore)
	cmd.Env = append(cmd.Env, "NOT_AFTER="+notAfter)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return err
	}
	if string(output) != "" {
		fmt.Println(string(output))
	}
	return nil
}

func AddClientHook(uid string) error {
	script := utils.EnvString("SCEP_ADD_CLIENT_SCRIPT", "")
	if script == "" {
		return nil
	}
	cmd := exec.Command(script)
	cmd.Env = append(cmd.Env, "UID="+uid)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return err
	}
	if string(output) != "" {
		fmt.Println(string(output))
	}
	return nil
}
