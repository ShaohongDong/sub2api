package dto

import (
	"testing"
	"time"

	"github.com/ShaohongDong/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestAPIKeyFromService_MapsLastUsedAt(t *testing.T) {
	lastUsed := time.Now().UTC().Truncate(time.Second)
	src := &service.APIKey{
		ID:         1,
		UserID:     2,
		Key:        "sk-map-last-used",
		Name:       "Mapper",
		Status:     service.StatusActive,
		LastUsedAt: &lastUsed,
	}

	out := APIKeyFromService(src)
	require.NotNil(t, out)
	require.NotNil(t, out.LastUsedAt)
	require.WithinDuration(t, lastUsed, *out.LastUsedAt, time.Second)
}

func TestAPIKeyFromService_MapsNilLastUsedAt(t *testing.T) {
	src := &service.APIKey{
		ID:     1,
		UserID: 2,
		Key:    "sk-map-last-used-nil",
		Name:   "MapperNil",
		Status: service.StatusActive,
	}

	out := APIKeyFromService(src)
	require.NotNil(t, out)
	require.Nil(t, out.LastUsedAt)
}

func TestAPIKeyFromService_MapsRateLimitResetTimesForActiveWindows(t *testing.T) {
	now := time.Now().UTC()
	start5h := now.Add(-2 * time.Hour)
	start1d := now.Add(-6 * time.Hour)
	start7d := now.Add(-48 * time.Hour)

	src := &service.APIKey{
		ID:            1,
		UserID:        2,
		Key:           "sk-rate-limit-reset",
		Name:          "MapperReset",
		Status:        service.StatusActive,
		Usage5h:       1.5,
		Usage1d:       2.5,
		Usage7d:       3.5,
		Window5hStart: &start5h,
		Window1dStart: &start1d,
		Window7dStart: &start7d,
	}

	out := APIKeyFromService(src)
	require.NotNil(t, out)
	require.NotNil(t, out.Reset5hAt)
	require.NotNil(t, out.Reset1dAt)
	require.NotNil(t, out.Reset7dAt)
	require.WithinDuration(t, start5h.Add(service.RateLimitWindow5h), *out.Reset5hAt, time.Second)
	require.WithinDuration(t, start1d.Add(service.RateLimitWindow1d), *out.Reset1dAt, time.Second)
	require.WithinDuration(t, start7d.Add(service.RateLimitWindow7d), *out.Reset7dAt, time.Second)
	require.Equal(t, 1.5, out.Usage5h)
	require.Equal(t, 2.5, out.Usage1d)
	require.Equal(t, 3.5, out.Usage7d)
}

func TestAPIKeyFromService_ExpiredWindowsClearUsageAndResetTimes(t *testing.T) {
	now := time.Now().UTC()
	start5h := now.Add(-service.RateLimitWindow5h - time.Minute)
	start1d := now.Add(-service.RateLimitWindow1d - time.Minute)
	start7d := now.Add(-service.RateLimitWindow7d - time.Minute)

	src := &service.APIKey{
		ID:            1,
		UserID:        2,
		Key:           "sk-rate-limit-expired",
		Name:          "MapperExpired",
		Status:        service.StatusActive,
		Usage5h:       1.5,
		Usage1d:       2.5,
		Usage7d:       3.5,
		Window5hStart: &start5h,
		Window1dStart: &start1d,
		Window7dStart: &start7d,
	}

	out := APIKeyFromService(src)
	require.NotNil(t, out)
	require.Nil(t, out.Reset5hAt)
	require.Nil(t, out.Reset1dAt)
	require.Nil(t, out.Reset7dAt)
	require.Zero(t, out.Usage5h)
	require.Zero(t, out.Usage1d)
	require.Zero(t, out.Usage7d)
}
