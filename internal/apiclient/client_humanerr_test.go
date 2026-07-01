package apiclient

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// humanAPIError renders the server envelope as one human line; unknown
// shapes clamp the raw body instead of swallowing it.
func TestHumanAPIError(t *testing.T) {
	err := humanAPIError(422, []byte(`{"error":{"code":"validation_failed","message":"task content failed validation","details":{"priority":["must be an integer 0..4, got \"3\""]},"request_id":"x"}}`))
	want := `task content failed validation — priority: must be an integer 0..4, got "3"`
	if err.Error() != want {
		t.Errorf("human error = %q, want %q", err.Error(), want)
	}

	err = humanAPIError(500, []byte("<html>gateway puke</html>"))
	if !strings.Contains(err.Error(), "error 500") || !strings.Contains(err.Error(), "gateway puke") {
		t.Errorf("fallback should clamp raw body, got %q", err.Error())
	}

	// A non-ASCII fallback body longer than the 200-char clamp must be cut on a
	// rune boundary — byte slicing would sever a multi-byte rune and emit
	// invalid UTF-8 to the status bar / logs.
	err = humanAPIError(503, []byte(strings.Repeat("æ", 300)))
	if !utf8.ValidString(err.Error()) {
		t.Errorf("clamped fallback must stay valid UTF-8, got %q", err.Error())
	}
	if !strings.HasSuffix(err.Error(), "…") {
		t.Errorf("clamped fallback should end with ellipsis, got %q", err.Error())
	}
}
