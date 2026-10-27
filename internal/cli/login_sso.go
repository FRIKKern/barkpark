package cli

// login_sso.go — `bp login --sso --org <slug>` (task under J5,
// task-fdb26f1d3d879593).
//
// An owner who signs in to a self-hosted instance only through the org's
// identity provider has no password, so `bp auth login` cannot help. This verb
// runs the instance's OIDC sign-in in the browser and takes the session the way
// a native app does (RFC 8252): a listener on 127.0.0.1 with a random port, a
// PKCE S256 challenge and a state. The instance's callback sends the browser to
// http://127.0.0.1:<port>/callback with a 60 s single-use ticket, and bp trades
// it at POST /v1/auth/sso/exchange with audience "bp-cli" and the verifier.
// The session is saved as that server's token in config.json (0600), the same
// slot `bp setup --target connect` fills. The token is never printed.
//
// `bp logout` revokes a session saved this way (runLogout).

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"
)

const loginSSOUsage = "bp login --sso --org <org> [-s <server>] [--no-browser]"

// ssoCLIAudience is the audience the instance binds a loopback ticket to. It is
// not an origin, so no Studio ticket can be traded with it and back.
const ssoCLIAudience = "bp-cli"

// ssoLoginWait bounds the wait for the browser. The instance forgets a started
// sign-in after 10 minutes, so waiting longer cannot succeed. A var for tests.
var ssoLoginWait = 10 * time.Minute

type loginSSOArgs struct {
	org       string
	noBrowser bool
}

// wantsSSOLogin reports whether `bp login` was asked for the SSO flow.
func wantsSSOLogin(args []string) bool {
	for _, a := range args {
		if a == "--sso" {
			return true
		}
	}
	return false
}

func parseLoginSSOArgs(args []string) (loginSSOArgs, error) {
	var a loginSSOArgs
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--sso":
		case arg == "--no-browser":
			a.noBrowser = true
		case arg == "--org":
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "-") {
				return a, fmt.Errorf("--org needs the org slug (usage: %s)", loginSSOUsage)
			}
			i++
			a.org = args[i]
		case strings.HasPrefix(arg, "--org="):
			a.org = strings.TrimPrefix(arg, "--org=")
		default:
			return a, fmt.Errorf("unexpected argument %q (usage: %s)", arg, loginSSOUsage)
		}
	}
	a.org = strings.TrimSpace(a.org)
	if a.org == "" {
		return a, fmt.Errorf("name the org whose SSO you sign in with: --org <slug> (usage: %s)", loginSSOUsage)
	}
	return a, nil
}

func runLoginSSO(out *writer, g globals, args []string) int {
	ctx := resolveContext(g)
	return ssoLogin(out, strings.TrimRight(strings.TrimSpace(ctx.Server), "/"), args)
}

func ssoLogin(out *writer, server string, args []string) int {
	a, err := parseLoginSSOArgs(args)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if server == "" {
		return useError(out, "usage", "name the instance with -s <url> (usage: "+loginSSOUsage+")", exitUsage)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return useError(out, "failed", "could not listen on 127.0.0.1 for the sign-in: "+err.Error(), exitGeneric)
	}
	defer ln.Close()
	returnTo := fmt.Sprintf("http://127.0.0.1:%d/callback", ln.Addr().(*net.TCPAddr).Port)

	verifier := randomB64(32)
	state := randomB64(24)
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"return_to":             {returnTo},
		"state":                 {state},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(sum[:])},
		"code_challenge_method": {"S256"},
	}
	startURL := server + "/v1/auth/oidc/" + url.PathEscape(a.org) + "/start?" + q.Encode()

	if code, msg, hint := ssoStartPreflight(startURL, server, a.org); code != "" {
		refuseWithRemedy(out, code, msg, hint)
		if code == "auth" {
			return exitAuth
		}
		return exitGeneric
	}

	type result struct {
		resp ssoExchangeResp
		err  error
	}
	done := make(chan result, 1)
	var taken atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		got := r.URL.Query()
		ticket := got.Get("ticket")
		if ticket == "" || subtle.ConstantTimeCompare([]byte(got.Get("state")), []byte(state)) != 1 ||
			!taken.CompareAndSwap(false, true) {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintln(w, "This sign-in does not match the one bp started. Run `bp login --sso` again.")
			return
		}
		resp, xerr := ssoExchange(server, ticket, verifier)
		if xerr != nil {
			w.WriteHeader(http.StatusBadGateway)
			fmt.Fprintln(w, "bp could not finish the sign-in. See the terminal.")
		} else {
			fmt.Fprintln(w, "Signed in. You can close this tab and return to the terminal.")
		}
		done <- result{resp, xerr}
	})
	httpSrv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = httpSrv.Serve(ln) }()
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(sctx)
	}()

	out.errf("Sign in to %s with the SSO of org %s.", server, a.org)
	if a.noBrowser {
		out.errf("Open this URL in a browser on this machine:")
	} else {
		out.errf("Opening your browser. If it does not open, visit this URL on this machine:")
	}
	out.errf("%s", startURL)
	if !a.noBrowser {
		if berr := browserOpener(startURL); berr != nil {
			out.errf("Could not start a browser (%v). Open the URL above yourself.", berr)
		}
	}
	out.errf("Waiting for the sign-in (up to %d minutes)...", int(ssoLoginWait.Minutes()))

	var res result
	select {
	case res = <-done:
	case <-time.After(ssoLoginWait):
		return useError(out, "timeout", "no sign-in reached bp within the wait. Run `bp login --sso` again", exitGeneric)
	}
	if res.err != nil {
		return useError(out, "auth", "the sign-in ticket was refused: "+res.err.Error(), exitAuth)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error()+". The session was not saved", exitGeneric)
	}
	entry, ok := cfg.FindServer(server)
	if !ok {
		entry = ServerEntry{Server: server}
	}
	replaced := ok && entry.Token != "" && entry.SSOOrg == ""
	entry.Token = res.resp.Token
	entry.SSOOrg = a.org
	entry.LastConnected = cloudClock().Format(time.RFC3339)
	cfg.RememberServer(entry)
	if serr := SaveConfig(cfg); serr != nil {
		return useError(out, "failed", "save config: "+serr.Error()+". The session was not saved", exitGeneric)
	}

	if out.emitStructured(map[string]any{
		"ok":         true,
		"server":     server,
		"org":        a.org,
		"email":      res.resp.User.Email,
		"expires_at": res.resp.ExpiresAt,
		"idp_mfa":    res.resp.IdpMFA,
	}) {
		return exitOK
	}
	out.outf("Signed in to %s as %s.", server, res.resp.User.Email)
	if res.resp.ExpiresAt != "" {
		out.outf("The session expires %s.", res.resp.ExpiresAt)
	}
	if res.resp.IdpMFA {
		out.outf("The identity provider reported MFA, so MFA-gated routes accept this session.")
	}
	if replaced {
		out.errf("This replaced the token bp had saved for %s.", server)
	}
	out.errf("Commands against this server now use the session. `bp logout` revokes it.")
	return exitOK
}

// ssoStartPreflight asks the instance for the start redirect without following
// it, so a missing connection or an instance without loopback support fails in
// the terminal instead of on a browser page. It returns an error code, message
// and hint, or "" when the instance answered with a redirect.
func ssoStartPreflight(startURL, server, org string) (string, string, string) {
	client := &http.Client{
		Timeout:       20 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Get(startURL)
	if err != nil {
		return "failed", "could not reach " + server + ": " + err.Error(), "check the URL, or pass the instance with -s <url>"
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return "", "", ""
	case resp.StatusCode == http.StatusNotFound:
		return "not_found", "org " + org + " has no OIDC connection on " + server, "check the slug with an operator, or see docs/setup/ENTRA.md"
	case resp.StatusCode == http.StatusBadRequest:
		return "unsupported", server + " refused the bp loopback sign-in (HTTP 400)",
			"the instance predates `bp login --sso`. Update it (on a VM: sudo git -C /opt/barkpark pull)"
	default:
		return "failed", fmt.Sprintf("%s answered HTTP %d to the sign-in start", server, resp.StatusCode), ""
	}
}

type ssoExchangeResp struct {
	Token string `json:"token"`
	User  struct {
		ID    string `json:"id"`
		Email string `json:"email"`
	} `json:"user"`
	ExpiresAt string `json:"expires_at"`
	IdpMFA    bool   `json:"idp_mfa"`
}

func ssoExchange(server, ticket, verifier string) (ssoExchangeResp, error) {
	var r ssoExchangeResp
	body, _ := json.Marshal(map[string]string{
		"ticket":        ticket,
		"audience":      ssoCLIAudience,
		"code_verifier": verifier,
	})
	status, respBody, err := doRequest("POST", server+"/v1/auth/sso/exchange",
		map[string]string{"Content-Type": "application/json"}, body)
	if err != nil {
		return r, err
	}
	if status != http.StatusCreated {
		return r, fmt.Errorf("HTTP %d from /v1/auth/sso/exchange", status)
	}
	if err := json.Unmarshal(respBody, &r); err != nil || r.Token == "" {
		return r, errors.New("the exchange answer had no session")
	}
	return r, nil
}

// ssoLogout revokes a session `bp login --sso` saved. It reports success only
// when the server's answer counts a revoked session.
func ssoLogout(server, token string) error {
	status, body, err := doRequest("DELETE", server+"/v1/auth/logout",
		map[string]string{"Authorization": "Bearer " + token}, nil)
	if err != nil {
		return err
	}
	if status == http.StatusUnauthorized {
		return errors.New("the server no longer had this session (HTTP 401)")
	}
	if status < 200 || status >= 300 {
		return fmt.Errorf("HTTP %d from /v1/auth/logout", status)
	}
	var r struct {
		Revoked int `json:"revoked"`
	}
	if json.Unmarshal(body, &r) != nil || r.Revoked < 1 {
		return errors.New("the logout answer counted no revoked session")
	}
	return nil
}

func randomB64(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
