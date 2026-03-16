package utils

import (
	"os"
	"strconv"
	"strings"
)

func EnvString(key, def string) string {
	if env := os.Getenv(key); env != "" {
		return env
	}
	return def
}

func EnvInt(key string, def int) int {
	if env := os.Getenv(key); env != "" {
		num, _ := strconv.Atoi(env)
		return num
	}
	return def
}

func EnvBool(key string) bool {
	if env := os.Getenv(key); env == "true" {
		return true
	}
	return false
}

func NormalizeDeviceID(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}
