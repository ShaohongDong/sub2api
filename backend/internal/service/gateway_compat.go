package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
)

// detachStreamUpstreamContext keeps streaming upstream requests alive even if the
// downstream client disconnects before the upstream request is fully established.
// The current code only needs a lightweight compatibility shim.
func detachStreamUpstreamContext(ctx context.Context, reqStream bool) (context.Context, func()) {
	if !reqStream {
		if ctx == nil {
			return context.Background(), func() {}
		}
		return ctx, func() {}
	}
	if ctx == nil {
		return context.Background(), func() {}
	}
	return context.WithoutCancel(ctx), func() {}
}

func HashUsageRequestPayload(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
