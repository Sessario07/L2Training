package web

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

// decode reads a JSON body with a size limit. Without MaxBytesReader a client
// can stream an unbounded body and drive the pod into an OOMKill - a trivially
// easy denial of service that is very easy to forget.
func decode(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 64<<10)) // 64 KiB
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func contextWithTimeout(r *http.Request, d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), d)
}
