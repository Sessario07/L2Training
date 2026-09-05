package obs

import (
	"os"
	"strings"
)

// Env reads configuration with support for the "_FILE" convention: if
// DATABASE_URL_FILE is set, the value is read from that file rather than from
// DATABASE_URL.
//
// This matters for secret delivery. The Secrets Store CSI driver mounts AWS
// Secrets Manager values as files in a tmpfs volume. Reading them from disk
// avoids two problems with the alternative (syncing to a Kubernetes Secret and
// using secretKeyRef):
//
//  1. Ordering. A synced Secret only exists once a pod mounting the
//     SecretProviderClass is running - but secretKeyRef is resolved BEFORE the
//     container starts. First deploy fails with CreateContainerConfigError.
//  2. Exposure. Environment variables leak into crash dumps, `kubectl describe`
//     of a pod spec, child processes, and any library that logs its config.
//     A file read once at startup does not.
//
// This is the same convention Docker secrets, Postgres and Grafana use.
func Env(key string) string {
	if path := os.Getenv(key + "_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err == nil {
			// Trailing newlines are extremely common in mounted secret files
			// and produce baffling authentication failures.
			return strings.TrimSpace(string(b))
		}
		// Fall through to the plain variable rather than failing outright, so a
		// misconfigured path degrades to the same error as a missing value.
	}
	return os.Getenv(key)
}

// EnvOr is Env with a default.
func EnvOr(key, def string) string {
	if v := Env(key); v != "" {
		return v
	}
	return def
}
