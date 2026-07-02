//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32DLL               = windows.NewLazySystemDLL("kernel32.dll")
	getConsoleProcessListProc = kernel32DLL.NewProc("GetConsoleProcessList")
)

func shouldShowDeviceIdentityReport(defaultProbeMode bool, jsonOutput bool) bool {
	return shouldShowDeviceIdentityInteractive(defaultProbeMode, jsonOutput, launchedFromStandaloneConsole())
}

func shouldShowDeviceIdentityInteractive(defaultProbeMode bool, jsonOutput bool, standaloneConsole bool) bool {
	return defaultProbeMode && !jsonOutput && standaloneConsole
}

func presentDeviceIdentityReport(output string) error {
	return openDeviceIdentityReport("MyTunnelApp device-id-probe result", output)
}

func presentDeviceIdentityError(err error) error {
	return openDeviceIdentityReport("MyTunnelApp device-id-probe error", fmt.Sprintf("device-id-probe failed.\r\n\r\n%v\r\n", err))
}

func openDeviceIdentityReport(title string, output string) error {
	content := strings.TrimSpace(output)
	if content == "" {
		content = "(no output)"
	}
	reportFile, err := createDeviceIdentityReportFile(title, content)
	if err != nil {
		return err
	}
	return exec.Command("notepad.exe", reportFile).Start()
}

func createDeviceIdentityReportFile(title string, output string) (string, error) {
	reportPath := filepath.Join(
		os.TempDir(),
		fmt.Sprintf("device-id-probe-%d.txt", time.Now().UTC().UnixNano()),
	)
	reportContent := fmt.Sprintf("%s\r\n\r\n%s\r\n", title, strings.TrimSpace(output))
	if err := os.WriteFile(reportPath, []byte(reportContent), 0o600); err != nil {
		return "", err
	}
	return reportPath, nil
}

func launchedFromStandaloneConsole() bool {
	processCount, err := consoleProcessCount()
	if err != nil {
		return false
	}
	return processCount == 1
}

func consoleProcessCount() (uint32, error) {
	processes := make([]uint32, 8)
	count, err := getConsoleProcessList(processes)
	if err != nil {
		return 0, err
	}
	if count > uint32(len(processes)) {
		processes = make([]uint32, count)
		return getConsoleProcessList(processes)
	}
	return count, nil
}

func getConsoleProcessList(processes []uint32) (uint32, error) {
	if len(processes) == 0 {
		return 0, nil
	}
	count, _, callErr := getConsoleProcessListProc.Call(
		uintptr(unsafe.Pointer(&processes[0])),
		uintptr(len(processes)),
	)
	if count == 0 {
		if callErr != windows.ERROR_SUCCESS && callErr != nil {
			return 0, callErr
		}
		return 0, fmt.Errorf("GetConsoleProcessList returned 0")
	}
	return uint32(count), nil
}
