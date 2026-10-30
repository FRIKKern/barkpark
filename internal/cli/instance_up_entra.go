package cli

// instance_up_entra.go adds the client secret to the app that entra.bicep
// made on the VM path. entra.bicep already makes the app, its service
// principal, admin consent and the owners group with its members, so up
// only needs the secret. It asks az once for a Microsoft Graph token and
// then calls Graph and the token endpoint itself.
//
// Each az command is a Python process. The final milestone 4 VM proofs on
// 2026-10-30 ran entra-app-register.sh here, which starts about 22 of them in
// a row. On a loaded Mac each took 20 to 40 s, so the step took 11 minutes.
// This way the step starts two: the entra.bicep deploy and the token.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

const instanceUpGraph = "https://graph.microsoft.com/v1.0"

// instanceUpGraphDo sends one request to Microsoft Graph with the token and
// returns the status and body. Tests replace it.
var instanceUpGraphDo = func(ctx context.Context, method, u, token string, body []byte) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, b, err
}

// instanceUpSecretAccepted asks the tenant's token endpoint for a client
// credentials token with the secret, and reports whether Entra gave one.
// The secret goes in the request body, never in a URL. Tests replace it.
var instanceUpSecretAccepted = func(ctx context.Context, tenant, clientID, secret string) bool {
	form := url.Values{"client_id": {clientID}, "client_secret": {secret},
		"scope": {"https://graph.microsoft.com/.default"}, "grant_type": {"client_credentials"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://login.microsoftonline.com/"+url.PathEscape(tenant)+"/oauth2/v2.0/token", strings.NewReader(form.Encode()))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// sub prints one sub-step with the UTC time it ended and how long it took,
// so a slow call shows in the output.
func (u *instanceUp) sub(start time.Time, format string, a ...any) {
	u.out.errf("        %s %s (%s)", time.Now().UTC().Format("15:04:05Z"), fmt.Sprintf(format, a...),
		time.Since(start).Round(100*time.Millisecond))
}

// graphError names the status and Graph's error message, never the body of
// a reply that can hold a secret.
func graphError(what string, code int, body []byte) error {
	var e struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	return fmt.Errorf("Microsoft Graph %s: status %d %s %s", what, code, e.Error.Code, e.Error.Message)
}

// graphReady sends a Graph request and repeats it while Graph answers 404,
// because a replica can lag the one entra.bicep wrote to. It ends as soon as
// Graph knows the object, and gives up after two minutes.
func (u *instanceUp) graphReady(what, method, url, token string, body []byte) ([]byte, error) {
	start := time.Now()
	for {
		code, b, err := instanceUpGraphDo(u.ctx, method, url, token, body)
		switch {
		case err != nil:
			return nil, fmt.Errorf("Microsoft Graph %s: %v", what, err)
		case code >= 200 && code < 300:
			return b, nil
		case code == http.StatusNotFound && time.Since(start) < 2*time.Minute:
			instanceUpSleep(3 * time.Second)
		default:
			return nil, graphError(what, code, b)
		}
	}
}

type instanceUpPasswordCredential struct {
	DisplayName string `json:"displayName"`
	EndDateTime string `json:"endDateTime"`
}

// secretExpiry formats a Graph endDateTime to whole seconds in UTC.
func secretExpiry(s string) string {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return s
	}
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

// entraSecret makes sure the app has a client secret in the secret file and
// returns when it expires. A secret file from an earlier run is kept. When
// the app has a secret but the file is gone, it stops, because Entra never
// shows a secret again. A new secret is written with mode 600 and never
// printed, and up waits until Entra accepts it.
func (u *instanceUp) entraSecret(tenant, appObjectID, clientID string) (string, error) {
	st := u.st
	file := st.secretFile()
	name := "barkpark-" + st.Org

	start := time.Now()
	var tok struct {
		AccessToken string `json:"accessToken"`
	}
	if err := u.az(&tok, "account", "get-access-token", "--resource-type", "ms-graph"); err != nil {
		return "", err
	}
	if tok.AccessToken == "" {
		return "", fmt.Errorf("az account get-access-token gave no Microsoft Graph token")
	}
	u.sub(start, "az gave a Microsoft Graph token")

	start = time.Now()
	appURL := instanceUpGraph + "/applications/" + url.PathEscape(appObjectID)
	b, err := u.graphReady("read the app", http.MethodGet, appURL+"?$select=passwordCredentials", tok.AccessToken, nil)
	if err != nil {
		return "", err
	}
	var app struct {
		PasswordCredentials []instanceUpPasswordCredential `json:"passwordCredentials"`
	}
	if err := json.Unmarshal(b, &app); err != nil {
		return "", fmt.Errorf("Microsoft Graph read the app: %v", err)
	}
	creds := app.PasswordCredentials
	u.sub(start, "Microsoft Graph has the app with %d client secret(s)", len(creds))

	if fi, err := os.Stat(file); err == nil && fi.Size() > 0 {
		_ = os.Chmod(file, 0o600)
		// The latest secret with this name, else the latest secret.
		sort.SliceStable(creds, func(i, j int) bool {
			if (creds[i].DisplayName == name) != (creds[j].DisplayName == name) {
				return creds[j].DisplayName == name
			}
			return creds[i].EndDateTime < creds[j].EndDateTime
		})
		expires := "unknown"
		if len(creds) > 0 {
			expires = secretExpiry(creds[len(creds)-1].EndDateTime)
		}
		u.out.errf("        keeping the client secret in %s", file)
		return expires, nil
	}
	if len(creds) > 0 {
		return "", fmt.Errorf("the app %s has a client secret, but %s is missing. Entra never shows a secret again. Delete the app's secret in the portal or the app itself, then run again", clientID, file)
	}

	start = time.Now()
	req, _ := json.Marshal(map[string]any{"passwordCredential": map[string]string{
		"displayName": name, "endDateTime": time.Now().UTC().AddDate(1, 0, 0).Format("2006-01-02T15:04:05Z")}})
	b, err = u.graphReady("add the client secret", http.MethodPost, appURL+"/addPassword", tok.AccessToken, req)
	if err != nil {
		return "", err
	}
	var made struct {
		SecretText  string `json:"secretText"`
		EndDateTime string `json:"endDateTime"`
	}
	if err := json.Unmarshal(b, &made); err != nil || made.SecretText == "" {
		return "", fmt.Errorf("Microsoft Graph added a client secret %q to the app %s but gave no secret text. Delete it in the portal, then run again", name, clientID)
	}
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, []byte(made.SecretText+"\n"), 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, file); err != nil {
		return "", err
	}
	expires := secretExpiry(made.EndDateTime)
	u.sub(start, "Microsoft Graph made the client secret %s, expires %s, in %s", name, expires, file)

	// Entra refuses a new secret (AADSTS7000215) for some seconds. Ask the
	// token endpoint until it accepts the secret three times in a row, for at
	// most 5 minutes. The 2026-10-27 drill saw refusals now and then for 9
	// minutes more, which a first secret can live with: no sign-in uses it yet.
	start = time.Now()
	ok, tries := 0, 0
	for ok < 3 && time.Since(start) < 5*time.Minute {
		tries++
		if instanceUpSecretAccepted(u.ctx, tenant, clientID, made.SecretText) {
			ok++
		} else {
			ok = 0
		}
		if ok < 3 {
			instanceUpSleep(3 * time.Second)
		}
	}
	if ok < 3 {
		u.sub(start, "Entra did not accept the new secret within 5 minutes. A sign-in that fails with AADSTS7000215 works when you try again later")
		return expires, nil
	}
	u.sub(start, "Entra accepts the new secret, %d token requests", tries)
	return expires, nil
}
