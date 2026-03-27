//go:build unit

package service

import (
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestForwardAsChatCompletions_Disabled_ReturnsBadRequest(t *testing.T) {
	t.Parallel()
	gin.SetMode(gin.TestMode)

	rec := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(rec)
	c.Request = httptest.NewRequest("POST", "/v1/chat/completions", nil)
	account := &Account{ID: 42, Platform: PlatformAnthropic}

	svc := &GatewayService{}
	result, err := svc.ForwardAsChatCompletions(c.Request.Context(), c, account, []byte(`{"model":"gpt-5"}`), &ParsedRequest{Model: "gpt-5"})

	require.Nil(t, result)
	require.EqualError(t, err, "anthropic chat completions compatibility disabled")
	require.Equal(t, 400, rec.Code)
	require.Contains(t, rec.Body.String(), anthropicChatCompletionsUnsupportedMessage)
	require.Contains(t, rec.Body.String(), `"invalid_request_error"`)
}

func TestForwardAsChatCompletions_Disabled_WithoutGinContextStillErrors(t *testing.T) {
	t.Parallel()

	svc := &GatewayService{}
	result, err := svc.ForwardAsChatCompletions(nil, nil, &Account{ID: 7, Platform: PlatformAnthropic}, nil, nil)

	require.Nil(t, result)
	require.EqualError(t, err, "anthropic chat completions compatibility disabled")
}
