//go:build unit

package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type updateCacheStub struct {
	data string
}

func (s *updateCacheStub) GetUpdateInfo(ctx context.Context) (string, error) {
	return s.data, nil
}

func (s *updateCacheStub) SetUpdateInfo(ctx context.Context, data string, ttl time.Duration) error {
	s.data = data
	return nil
}

type githubReleaseClientStub struct {
	repoArg      string
	fetchCalls   int
	latestRelease *GitHubRelease
}

func (s *githubReleaseClientStub) FetchLatestRelease(ctx context.Context, repo string) (*GitHubRelease, error) {
	s.fetchCalls++
	s.repoArg = repo
	return s.latestRelease, nil
}

func (s *githubReleaseClientStub) DownloadFile(ctx context.Context, url, dest string, maxSize int64) error {
	panic("unexpected DownloadFile call")
}

func (s *githubReleaseClientStub) FetchChecksumFile(ctx context.Context, url string) ([]byte, error) {
	panic("unexpected FetchChecksumFile call")
}

func TestUpdateService_CheckUpdate_InvalidatesLegacyRepoCache(t *testing.T) {
	cache := &updateCacheStub{
		data: `{"latest":"1.2.3","release_info":{"html_url":"https://github.com/Wei-Shaw/sub2api/releases/tag/v1.2.3"},"timestamp":4102444800}`,
	}
	githubClient := &githubReleaseClientStub{
		latestRelease: &GitHubRelease{
			TagName:     "v1.2.4",
			Name:        "v1.2.4",
			HTMLURL:     "https://github.com/ShaohongDong/sub2api/releases/tag/v1.2.4",
			PublishedAt: "2026-03-07T00:00:00Z",
		},
	}
	svc := NewUpdateService(cache, githubClient, "1.2.3", "release")

	info, err := svc.CheckUpdate(context.Background(), false)
	require.NoError(t, err)
	require.Equal(t, 1, githubClient.fetchCalls)
	require.Equal(t, githubRepo, githubClient.repoArg)
	require.NotNil(t, info.ReleaseInfo)
	require.Equal(t, "https://github.com/ShaohongDong/sub2api/releases/tag/v1.2.4", info.ReleaseInfo.HTMLURL)
	require.False(t, info.Cached)
	require.Contains(t, cache.data, `"repo":"ShaohongDong/sub2api"`)
}
