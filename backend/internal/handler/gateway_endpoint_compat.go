package handler

import (
	"strings"

	"github.com/ShaohongDong/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

const (
	inboundEndpointContextKey  = "gateway_inbound_endpoint"
	upstreamEndpointContextKey = "gateway_upstream_endpoint"
)

func InboundEndpointMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c != nil {
			if endpoint := normalizedInboundEndpoint(c); endpoint != "" {
				c.Set(inboundEndpointContextKey, endpoint)
			}
		}
		c.Next()
	}
}

func setOpsEndpointContext(c *gin.Context, inboundEndpoint string, _ int16) {
	if c == nil {
		return
	}
	inboundEndpoint = strings.TrimSpace(inboundEndpoint)
	if inboundEndpoint == "" {
		inboundEndpoint = normalizedInboundEndpoint(c)
	}
	if inboundEndpoint != "" {
		c.Set(inboundEndpointContextKey, inboundEndpoint)
	}
}

func GetInboundEndpoint(c *gin.Context) string {
	if c == nil {
		return ""
	}
	if v, ok := c.Get(inboundEndpointContextKey); ok {
		if endpoint, ok := v.(string); ok && strings.TrimSpace(endpoint) != "" {
			return strings.TrimSpace(endpoint)
		}
	}
	return normalizedInboundEndpoint(c)
}

func GetUpstreamEndpoint(c *gin.Context, platform string) string {
	if c == nil {
		return ""
	}
	if v, ok := c.Get(upstreamEndpointContextKey); ok {
		if endpoint, ok := v.(string); ok && strings.TrimSpace(endpoint) != "" {
			return strings.TrimSpace(endpoint)
		}
	}

	inbound := GetInboundEndpoint(c)
	switch platform {
	case service.PlatformAnthropic, service.PlatformAntigravity:
		switch {
		case strings.Contains(inbound, "/messages/count_tokens"):
			return "/v1/messages/count_tokens"
		case strings.Contains(inbound, "/responses"), strings.Contains(inbound, "/chat/completions"), strings.Contains(inbound, "/messages"):
			return "/v1/messages"
		}
	case service.PlatformOpenAI, service.PlatformSora:
		if inbound != "" {
			return inbound
		}
	}
	return inbound
}

func normalizedInboundEndpoint(c *gin.Context) string {
	if c == nil || c.Request == nil {
		return ""
	}
	if fullPath := strings.TrimSpace(c.FullPath()); fullPath != "" {
		return fullPath
	}
	return strings.TrimSpace(c.Request.URL.Path)
}
