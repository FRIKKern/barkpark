package cloudclient

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

// TestDeviceStartDecodesPair drives DeviceStart against a fake control plane and
// asserts the request shape (unauthed POST, client_name in the body) and that the
// full code pair + poll hints decode.
func TestDeviceStartDecodesPair(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		gotBody = readJSON(t, r)
		_, _ = io.WriteString(w, `{
			"device_code":"dev-secret-xyz",
			"user_code":"WXYZ-1234",
			"verification_uri":"https://api.barkpark.cloud/device",
			"verification_uri_complete":"https://api.barkpark.cloud/device?code=WXYZ-1234",
			"interval":5,
			"expires_in":900
		}`)
	})

	ds, err := c.DeviceStart(context.Background(), "bp on laptop")
	if err != nil {
		t.Fatalf("DeviceStart: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/auth/device/start" {
		t.Fatalf("hit %s %s, want POST /v1/auth/device/start", gotMethod, gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("device start must be unauthed; got %q", gotAuth)
	}
	if gotBody["client_name"] != "bp on laptop" {
		t.Fatalf("client_name = %v, want 'bp on laptop'", gotBody["client_name"])
	}
	if ds.DeviceCode != "dev-secret-xyz" || ds.UserCode != "WXYZ-1234" {
		t.Fatalf("codes = %+v", ds)
	}
	if ds.VerificationURI == "" || ds.VerificationURIComplete == "" {
		t.Fatalf("verification URIs missing: %+v", ds)
	}
	if ds.Interval != 5 || ds.ExpiresIn != 900 {
		t.Fatalf("interval/expiry = %d/%d, want 5/900", ds.Interval, ds.ExpiresIn)
	}
}

// TestDeviceStartOmitsEmptyClientName: a blank client name is left off the wire.
func TestDeviceStartOmitsEmptyClientName(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		_, _ = io.WriteString(w, `{"device_code":"d","user_code":"AAAA-BBBB","verification_uri":"https://x/device","interval":5,"expires_in":600}`)
	})
	if _, err := c.DeviceStart(context.Background(), ""); err != nil {
		t.Fatalf("DeviceStart: %v", err)
	}
	if _, present := gotBody["client_name"]; present {
		t.Fatalf("empty client_name must be omitted; got %v", gotBody)
	}
}

// TestDeviceStartSurfacesRateLimit: a 429 (the endpoint's rate limit) surfaces
// the control plane's error verbatim via cloudError, not a swallowed failure.
func TestDeviceStartSurfacesRateLimit(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(w, `{"error":"rate_limited"}`)
	})
	_, err := c.DeviceStart(context.Background(), "bp")
	if err == nil {
		t.Fatal("expected an error on 429")
	}
	if !strings.Contains(err.Error(), "rate_limited") {
		t.Fatalf("error should surface rate_limited; got %v", err)
	}
}

// TestDevicePollPending: a 4xx authorization_pending is the steady poll state —
// NOT an error, decoded as DevicePollPending with the deviceCode echoed in the body.
func TestDevicePollPending(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":"authorization_pending"}`)
	})
	res, err := c.DevicePoll(context.Background(), "dev-secret-xyz")
	if err != nil {
		t.Fatalf("pending must not be an error; got %v", err)
	}
	if res.Status != DevicePollPending {
		t.Fatalf("status = %d, want DevicePollPending", res.Status)
	}
	if gotBody["device_code"] != "dev-secret-xyz" {
		t.Fatalf("device_code = %v", gotBody["device_code"])
	}
}

// TestDevicePollSlowDown: a 4xx slow_down decodes as DevicePollSlowDown, again
// not an error.
func TestDevicePollSlowDown(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = io.WriteString(w, `{"error":"slow_down"}`)
	})
	res, err := c.DevicePoll(context.Background(), "d")
	if err != nil {
		t.Fatalf("slow_down must not be an error; got %v", err)
	}
	if res.Status != DevicePollSlowDown {
		t.Fatalf("status = %d, want DevicePollSlowDown", res.Status)
	}
}

// TestDevicePollApproved: a 200 carrying the token decodes as Approved with the
// SAME LoginResp a password login yields.
func TestDevicePollApproved(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"token":"sess-approved","team_id":"team-9"}`)
	})
	res, err := c.DevicePoll(context.Background(), "d")
	if err != nil {
		t.Fatalf("DevicePoll: %v", err)
	}
	if res.Status != DevicePollApproved {
		t.Fatalf("status = %d, want DevicePollApproved", res.Status)
	}
	if res.Login.Token != "sess-approved" || res.Login.TeamID != "team-9" {
		t.Fatalf("login = %+v", res.Login)
	}
}

// TestDevicePollTerminalErrors: access_denied and expired_token are terminal —
// they surface as Go errors (via cloudError) so the caller stops the loop.
func TestDevicePollTerminalErrors(t *testing.T) {
	for _, code := range []string{"access_denied", "expired_token"} {
		code := code
		t.Run(code, func(t *testing.T) {
			c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"`+code+`"}`)
			})
			_, err := c.DevicePoll(context.Background(), "d")
			if err == nil {
				t.Fatalf("%s must be a terminal error", code)
			}
			if !strings.Contains(err.Error(), code) {
				t.Fatalf("error should carry %q; got %v", code, err)
			}
		})
	}
}
