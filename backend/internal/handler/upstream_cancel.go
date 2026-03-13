package handler

import (
	"context"
	"errors"
	"strings"

	"github.com/ShaohongDong/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

func isContextCanceledText(s string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(s)), "context canceled")
}

func hasContextCanceledUpstreamSignal(c *gin.Context) bool {
	if c == nil {
		return false
	}
	if v, ok := c.Get(service.OpsUpstreamErrorMessageKey); ok {
		if s, ok := v.(string); ok && isContextCanceledText(s) {
			return true
		}
	}
	if v, ok := c.Get(service.OpsUpstreamErrorDetailKey); ok {
		if s, ok := v.(string); ok && isContextCanceledText(s) {
			return true
		}
	}
	if v, ok := c.Get(service.OpsUpstreamErrorsKey); ok {
		if events, ok := v.([]*service.OpsUpstreamErrorEvent); ok {
			for _, ev := range events {
				if ev == nil {
					continue
				}
				if isContextCanceledText(ev.Message) || isContextCanceledText(ev.Detail) {
					return true
				}
			}
		}
	}
	return false
}

func isClientCanceledForwardError(c *gin.Context, err error) bool {
	if errors.Is(err, context.Canceled) {
		return true
	}
	if err != nil && isContextCanceledText(err.Error()) {
		return true
	}
	return hasContextCanceledUpstreamSignal(c)
}
