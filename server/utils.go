package scepserver

import (
	"os"
	"strconv"
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
