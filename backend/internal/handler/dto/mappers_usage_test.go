package dto

import (
	"testing"
	"time"

	"github.com/ShaohongDong/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestUsageLogFromService_IncludesOpenAIWSMode(t *testing.T) {
	t.Parallel()

	wsLog := &service.UsageLog{
		RequestID:    "req_1",
		Model:        "gpt-5.3-codex",
		OpenAIWSMode: true,
	}
	httpLog := &service.UsageLog{
		RequestID:    "resp_1",
		Model:        "gpt-5.3-codex",
		OpenAIWSMode: false,
	}

	require.True(t, UsageLogFromService(wsLog).OpenAIWSMode)
	require.False(t, UsageLogFromService(httpLog).OpenAIWSMode)
	require.True(t, UsageLogFromServiceAdmin(wsLog).OpenAIWSMode)
	require.False(t, UsageLogFromServiceAdmin(httpLog).OpenAIWSMode)
}

func TestUsageLogFromService_PrefersRequestTypeForLegacyFields(t *testing.T) {
	t.Parallel()

	log := &service.UsageLog{
		RequestID:    "req_2",
		Model:        "gpt-5.3-codex",
		RequestType:  service.RequestTypeWSV2,
		Stream:       false,
		OpenAIWSMode: false,
	}

	userDTO := UsageLogFromService(log)
	adminDTO := UsageLogFromServiceAdmin(log)

	require.Equal(t, "ws_v2", userDTO.RequestType)
	require.True(t, userDTO.Stream)
	require.True(t, userDTO.OpenAIWSMode)
	require.Equal(t, "ws_v2", adminDTO.RequestType)
	require.True(t, adminDTO.Stream)
	require.True(t, adminDTO.OpenAIWSMode)
}

func TestUsageCleanupTaskFromService_RequestTypeMapping(t *testing.T) {
	t.Parallel()

	requestType := int16(service.RequestTypeStream)
	task := &service.UsageCleanupTask{
		ID:     1,
		Status: service.UsageCleanupStatusPending,
		Filters: service.UsageCleanupFilters{
			RequestType: &requestType,
		},
	}

	dtoTask := UsageCleanupTaskFromService(task)
	require.NotNil(t, dtoTask)
	require.NotNil(t, dtoTask.Filters.RequestType)
	require.Equal(t, "stream", *dtoTask.Filters.RequestType)
}

func TestRequestTypeStringPtrNil(t *testing.T) {
	t.Parallel()
	require.Nil(t, requestTypeStringPtr(nil))
}

func TestAPIKeyFromService_IncludesResetTimesForActiveWindows(t *testing.T) {
	t.Parallel()

	now := time.Now()
	start5h := now.Add(-2 * time.Hour)
	start1d := now.Add(-6 * time.Hour)
	start7d := now.Add(-24 * time.Hour)

	key := &service.APIKey{
		ID:            1,
		Name:          "sk-test",
		RateLimit5h:   10,
		RateLimit1d:   20,
		RateLimit7d:   30,
		Window5hStart: &start5h,
		Window1dStart: &start1d,
		Window7dStart: &start7d,
	}

	dtoKey := APIKeyFromService(key)
	require.NotNil(t, dtoKey)
	require.NotNil(t, dtoKey.Reset5hAt)
	require.NotNil(t, dtoKey.Reset1dAt)
	require.NotNil(t, dtoKey.Reset7dAt)
	require.WithinDuration(t, start5h.Add(service.RateLimitWindow5h), *dtoKey.Reset5hAt, time.Second)
	require.WithinDuration(t, start1d.Add(service.RateLimitWindow1d), *dtoKey.Reset1dAt, time.Second)
	require.WithinDuration(t, start7d.Add(service.RateLimitWindow7d), *dtoKey.Reset7dAt, time.Second)
}

func TestAPIKeyFromService_OmitsResetTimesForExpiredWindows(t *testing.T) {
	t.Parallel()

	now := time.Now()
	start5h := now.Add(-service.RateLimitWindow5h - time.Minute)
	start1d := now.Add(-service.RateLimitWindow1d - time.Minute)
	start7d := now.Add(-service.RateLimitWindow7d - time.Minute)

	key := &service.APIKey{
		ID:            2,
		Name:          "sk-expired",
		RateLimit5h:   10,
		RateLimit1d:   20,
		RateLimit7d:   30,
		Window5hStart: &start5h,
		Window1dStart: &start1d,
		Window7dStart: &start7d,
	}

	dtoKey := APIKeyFromService(key)
	require.NotNil(t, dtoKey)
	require.Nil(t, dtoKey.Reset5hAt)
	require.Nil(t, dtoKey.Reset1dAt)
	require.Nil(t, dtoKey.Reset7dAt)
}
