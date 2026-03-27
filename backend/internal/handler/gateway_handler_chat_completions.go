package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// ChatCompletions remains disabled for Anthropic platform groups on this branch.
// The underlying conversion layer was not present in the selected upstream set.
func (h *GatewayHandler) ChatCompletions(c *gin.Context) {
	h.chatCompletionsErrorResponse(
		c,
		http.StatusBadRequest,
		"invalid_request_error",
		"Chat Completions compatibility for Anthropic groups is temporarily unavailable. Please use /v1/responses or /v1/messages.",
	)
}

// chatCompletionsErrorResponse writes an error in OpenAI Chat Completions format.
func (h *GatewayHandler) chatCompletionsErrorResponse(c *gin.Context, status int, errType, message string) {
	c.JSON(status, gin.H{
		"error": gin.H{
			"type":    errType,
			"message": message,
		},
	})
}
