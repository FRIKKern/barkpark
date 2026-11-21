package main

import (
	"testing"
)

// TestClaudeProtocolParsing tests session ID extraction from real Claude Code output formats.
// These are based on expected formats from the official claude CLI.
// NOT tested against real Claude subscription - these are protocol fixtures.
func TestClaudeProtocolParsing(t *testing.T) {
	tests := []struct {
		name           string
		claudeOutput   string
		wantSessionID  string
		wantAuthError  bool
		description    string
	}{
		{
			name: "successful completion with session",
			claudeOutput: `Starting new conversation...
Session: sess-abc123def456
[Assistant response here]
Completed successfully.`,
			wantSessionID: "sess-abc123def456",
			wantAuthError: false,
			description:   "Normal successful response with session ID",
		},
		{
			name: "session ID with dashes",
			claudeOutput: `session: task-789-xyz-123
[Response content]`,
			wantSessionID: "task-789-xyz-123",
			wantAuthError: false,
			description:   "Session ID with multiple dashes",
		},
		{
			name: "authentication error",
			claudeOutput: `Error: not authenticated
Please run: claude setup-token`,
			wantSessionID: "",
			wantAuthError: true,
			description:   "Clear authentication error",
		},
		{
			name: "oauth token missing",
			claudeOutput: `Error: CLAUDE_CODE_OAUTH_TOKEN not set
Authentication required`,
			wantSessionID: "",
			wantAuthError: true,
			description:   "Missing OAuth token",
		},
		{
			name: "no session in output",
			claudeOutput: `Some response without session info
Just normal text`,
			wantSessionID: "",
			wantAuthError: false,
			description:   "Response without session marker",
		},
		{
			name: "multiple session markers (use first)",
			claudeOutput: `session: first-session-123
Some content
session: second-session-456`,
			wantSessionID: "first-session-123",
			wantAuthError: false,
			description:   "Multiple session markers - should use first",
		},
		{
			name: "Session ID with colon prefix",
			claudeOutput: `Starting conversation
Session ID: conv-abc-123
Response follows`,
			wantSessionID: "conv-abc-123",
			wantAuthError: false,
			description:   "Session ID with capital letters and colon",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Test session ID extraction
			gotSessionID := extractSessionID([]byte(tt.claudeOutput))
			if gotSessionID != tt.wantSessionID {
				t.Errorf("extractSessionID() = %q, want %q\nOutput: %s\nDescription: %s",
					gotSessionID, tt.wantSessionID, tt.claudeOutput, tt.description)
			}

			// Test auth error detection
			gotAuthError := isAuthError(tt.claudeOutput)
			if gotAuthError != tt.wantAuthError {
				t.Errorf("isAuthError() = %v, want %v\nOutput: %s\nDescription: %s",
					gotAuthError, tt.wantAuthError, tt.claudeOutput, tt.description)
			}
		})
	}
}

// TestAuthErrorPatterns tests various authentication error formats
func TestAuthErrorPatterns(t *testing.T) {
	authErrors := []string{
		"not authenticated",
		"Not Authenticated",
		"NOT AUTHENTICATED",
		"authentication required",
		"Authentication Required",
		"CLAUDE_CODE_OAUTH_TOKEN not set",
		"claude_code_oauth_token missing",
		"Please run: claude setup-token",
		"setup-token required",
		"Auth failed",
		"auth failed: token invalid",
		"unauthenticated request",
	}

	for _, errMsg := range authErrors {
		t.Run(errMsg, func(t *testing.T) {
			if !isAuthError(errMsg) {
				t.Errorf("isAuthError(%q) = false, want true", errMsg)
			}
		})
	}

	// Non-auth errors should return false
	nonAuthErrors := []string{
		"rate limit exceeded",
		"invalid prompt",
		"timeout",
		"network error",
		"internal server error",
	}

	for _, errMsg := range nonAuthErrors {
		t.Run("not_auth_"+errMsg, func(t *testing.T) {
			if isAuthError(errMsg) {
				t.Errorf("isAuthError(%q) = true, want false", errMsg)
			}
		})
	}
}

// TestSessionIDFormats tests various session ID format variations
func TestSessionIDFormats(t *testing.T) {
	validFormats := []struct {
		output    string
		sessionID string
	}{
		{"session: abc123", "abc123"},
		{"Session: def456", "def456"},
		{"SESSION: ghi789", "ghi789"},
		{"session:jkl012", "jkl012"}, // No space
		{"Session ID: mno345", "mno345"},
		{"session id: pqr678", "pqr678"},
		{"SESSION ID: stu901", "stu901"},
	}

	for _, tc := range validFormats {
		t.Run(tc.sessionID, func(t *testing.T) {
			got := extractSessionID([]byte(tc.output))
			if got != tc.sessionID {
				t.Errorf("extractSessionID(%q) = %q, want %q", tc.output, got, tc.sessionID)
			}
		})
	}
}
