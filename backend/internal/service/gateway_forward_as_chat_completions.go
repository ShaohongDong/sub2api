package service

import (
	"context"
	"fmt"
	"net/http"

	"github.com/ShaohongDong/sub2api/internal/pkg/logger"
	"github.com/gin-gonic/gin"
)

const anthropicChatCompletionsUnsupportedMessage = "Chat Completions compatibility for Anthropic groups is temporarily unavailable. Please use /v1/responses or /v1/messages."

// ForwardAsChatCompletions is intentionally disabled on this branch.
//
// The cherry-picked Anthropic compatibility chain brought in handlers/routes
// before the corresponding apicompat Chat Completions converters landed.  Keep
// the method as a guarded stub so the rest of the Claude/Responses integration
// can compile and ship safely.
func (s *GatewayService) ForwardAsChatCompletions(
	_ context.Context,
	c *gin.Context,
	account *Account,
	_ []byte,
	_ *ParsedRequest,
) (*ForwardResult, error) {
	if account != nil {
		logger.LegacyPrintf("service.gateway", "chat_completions_compat_disabled account=%d platform=%s", account.ID, account.Platform)
	}
	if c != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": gin.H{
				"type":    "invalid_request_error",
				"message": anthropicChatCompletionsUnsupportedMessage,
			},
		})
	}
	return nil, fmt.Errorf("anthropic chat completions compatibility disabled")
}
