package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// ChatCompletions is intentionally unsupported for OpenAI platform groups on
// this branch; they must use the Responses API entrypoint.
func (h *OpenAIGatewayHandler) ChatCompletions(c *gin.Context) {
	h.errorResponse(
		c,
		http.StatusBadRequest,
		"invalid_request_error",
		"Unsupported legacy protocol: /v1/chat/completions is not supported. Please use /v1/responses.",
	)
}
