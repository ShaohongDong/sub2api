package openai

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"sync"
	"testing"
	"time"
)

func TestSessionStore_Stop_Idempotent(t *testing.T) {
	store := NewSessionStore()

	store.Stop()
	store.Stop()

	select {
	case <-store.stopCh:
		// ok
	case <-time.After(time.Second):
		t.Fatal("stopCh 未关闭")
	}
}

func TestSessionStore_Stop_Concurrent(t *testing.T) {
	store := NewSessionStore()

	var wg sync.WaitGroup
	for range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			store.Stop()
		}()
	}

	wg.Wait()

	select {
	case <-store.stopCh:
		// ok
	case <-time.After(time.Second):
		t.Fatal("stopCh 未关闭")
	}
}

func TestBuildAuthorizationURLForPlatform_OpenAI(t *testing.T) {
	authURL := BuildAuthorizationURLForPlatform("state-1", "challenge-1", DefaultRedirectURI, OAuthPlatformOpenAI)
	parsed, err := url.Parse(authURL)
	if err != nil {
		t.Fatalf("Parse URL failed: %v", err)
	}
	q := parsed.Query()
	if got := q.Get("client_id"); got != ClientID {
		t.Fatalf("client_id mismatch: got=%q want=%q", got, ClientID)
	}
	if got := q.Get("codex_cli_simplified_flow"); got != "true" {
		t.Fatalf("codex flow mismatch: got=%q want=true", got)
	}
	if got := q.Get("id_token_add_organizations"); got != "true" {
		t.Fatalf("id_token_add_organizations mismatch: got=%q want=true", got)
	}
}

// TestBuildAuthorizationURLForPlatform_Sora 验证 Sora 平台复用 Codex CLI 的 client_id，
// 但不启用 codex_cli_simplified_flow。
func TestBuildAuthorizationURLForPlatform_Sora(t *testing.T) {
	authURL := BuildAuthorizationURLForPlatform("state-2", "challenge-2", DefaultRedirectURI, OAuthPlatformSora)
	parsed, err := url.Parse(authURL)
	if err != nil {
		t.Fatalf("Parse URL failed: %v", err)
	}
	q := parsed.Query()
	if got := q.Get("client_id"); got != ClientID {
		t.Fatalf("client_id mismatch: got=%q want=%q (Sora should reuse Codex CLI client_id)", got, ClientID)
	}
	if got := q.Get("codex_cli_simplified_flow"); got != "" {
		t.Fatalf("codex flow should be empty for sora, got=%q", got)
	}
	if got := q.Get("id_token_add_organizations"); got != "true" {
		t.Fatalf("id_token_add_organizations mismatch: got=%q want=true", got)
	}
}

func TestDecodeIDToken_GetUserInfoIncludesPlanTypeAndDefaultOrganization(t *testing.T) {
	t.Parallel()

	token := buildUnsignedIDToken(t, map[string]any{
		"email": "alice@example.com",
		"https://api.openai.com/auth": map[string]any{
			"chatgpt_account_id": "acct_123",
			"chatgpt_user_id":    "user_456",
			"chatgpt_plan_type":  "pro",
			"user_id":            "u_789",
			"organizations": []map[string]any{
				{"id": "org_secondary", "is_default": false},
				{"id": "org_primary", "is_default": true},
			},
		},
	})

	claims, err := DecodeIDToken(token)
	if err != nil {
		t.Fatalf("DecodeIDToken failed: %v", err)
	}

	info := claims.GetUserInfo()
	if info == nil {
		t.Fatal("GetUserInfo returned nil")
	}
	if info.Email != "alice@example.com" {
		t.Fatalf("email mismatch: got=%q", info.Email)
	}
	if info.PlanType != "pro" {
		t.Fatalf("plan type mismatch: got=%q", info.PlanType)
	}
	if info.ChatGPTAccountID != "acct_123" {
		t.Fatalf("account id mismatch: got=%q", info.ChatGPTAccountID)
	}
	if info.ChatGPTUserID != "user_456" {
		t.Fatalf("user id mismatch: got=%q", info.ChatGPTUserID)
	}
	if info.OrganizationID != "org_primary" {
		t.Fatalf("organization id mismatch: got=%q", info.OrganizationID)
	}
}

func TestDecodeIDToken_AllowsExpiredPayloadWhileParseRejectsIt(t *testing.T) {
	t.Parallel()

	token := buildUnsignedIDToken(t, map[string]any{
		"email": "expired@example.com",
		"exp":   time.Now().Add(-10 * time.Minute).Unix(),
	})

	claims, err := DecodeIDToken(token)
	if err != nil {
		t.Fatalf("DecodeIDToken failed: %v", err)
	}
	if claims.Email != "expired@example.com" {
		t.Fatalf("email mismatch: got=%q", claims.Email)
	}

	if _, err := ParseIDToken(token); err == nil {
		t.Fatal("ParseIDToken should reject expired token")
	}
}

func TestDecodeIDToken_GetUserInfoFallsBackToFirstOrganization(t *testing.T) {
	t.Parallel()

	token := buildUnsignedIDToken(t, map[string]any{
		"email": "fallback@example.com",
		"https://api.openai.com/auth": map[string]any{
			"chatgpt_plan_type": "plus",
			"organizations": []map[string]any{
				{"id": "org_first", "is_default": false},
				{"id": "org_second", "is_default": false},
			},
		},
	})

	claims, err := DecodeIDToken(token)
	if err != nil {
		t.Fatalf("DecodeIDToken failed: %v", err)
	}

	info := claims.GetUserInfo()
	if info == nil {
		t.Fatal("GetUserInfo returned nil")
	}
	if info.OrganizationID != "org_first" {
		t.Fatalf("organization fallback mismatch: got=%q", info.OrganizationID)
	}
}

func buildUnsignedIDToken(t *testing.T, claims map[string]any) string {
	t.Helper()

	header, err := json.Marshal(map[string]any{"alg": "none", "typ": "JWT"})
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	encode := func(src []byte) string {
		return base64.RawURLEncoding.EncodeToString(src)
	}

	return encode(header) + "." + encode(payload) + ".signature"
}
