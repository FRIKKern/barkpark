package apiclient

import (
	"strings"
	"testing"
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
}
