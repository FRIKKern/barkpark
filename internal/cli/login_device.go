package cli

// login_device.go is the COPY-A-LINK browser half of `bp login` — the
// Claude-Code-style device-authorization flow (charter decision 10-12). Where
// the password path in cloud12_cmd.go prompts email + password in the terminal,
// this path never asks for a credential: it opens a device session against the
// control plane, boxes a short verification URL + code to stderr, best-effort
// opens the browser, and polls until the user approves in their existing
// barkpark.cloud session — then stores the same {token, team_id} in config 0600,
// byte-identical to a password login.
//
// runDeviceLoginFlow is factored out as a package-level, self-contained routine
// so BOTH runLoginCloud (the gated `bp login` path) and the first-run wizard
// (bp-login-ux S4) drive the exact same experience from one implementation. ALL
// chrome — the box, the browser prompt, the polling dots — goes to stderr via
// out.errf, so `-o json` still emits nothing but the final envelope on stdout.

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-isatty"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// Poll seams — package vars so tests run instantly (the instPoll idiom,
// hetzner_instance_cmd.go). devicePoll is the fallback spacing when the control
// plane omits an interval; devicePollMax bounds the total number of polls before
// the CLI gives up waiting for a human. deviceSleep is the between-poll wait,
// swappable in tests so a poll loop finishes in microseconds.
var (
	devicePoll    = 5 * time.Second
	devicePollMax = 180
	deviceSleep   = time.Sleep
)

// deviceTTYCheck reports whether BOTH stdin and stdout are real terminals — the
// gate (alongside zero credentials) that offers the browser device-login instead
// of the password prompt. A package var so a gating-table test can force it
// without allocating a pseudo-terminal (the canRunWizard both-streams idiom).
var deviceTTYCheck = func() bool {
	return isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stdout.Fd())
}

// deviceAuthError marks a device-login failure that is an AUTHENTICATION problem
// — the user denied it, the code expired, or we timed out waiting for approval —
// so runLoginCloud maps it to exitAuth (3), distinct from a transport failure
// (exitGeneric). errors.As recovers it from a wrapped chain.
type deviceAuthError struct{ msg string }

func (e *deviceAuthError) Error() string { return e.msg }

// deviceEmailFallback is the always-present escape hatch line: the device flow
// is the friendly default, but email+password is one flag away for headless / CI
// use. Rendered under the box and echoed in every give-up message.
const deviceEmailFallback = "Or log in with email:  bp login --email you@example.com"

// device box styling. Border chars render on every profile; the foreground
// accents collapse to plain text under lipgloss's Ascii profile (a non-tty),
// so buffered test output stays free of stray SGR around the URL and code.
var (
	deviceBoxBorder = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	deviceBoxTitle  = lipgloss.NewStyle().Bold(true)
	deviceBoxURL    = lipgloss.NewStyle().Underline(true)
	deviceBoxCode   = lipgloss.NewStyle().Bold(true)
)

// deviceClientName is the human label the approve page shows for this pending
// grant, so a user approving in the browser sees WHICH machine asked. Falls back
// to a bare "bp" when the hostname is unavailable.
func deviceClientName() string {
	h, err := os.Hostname()
	if err != nil || strings.TrimSpace(h) == "" {
		return "bp"
	}
	return "bp on " + strings.TrimSpace(h)
}

// runDeviceLoginFlow drives the whole copy-a-link login against base and stores
// the session on success. It is self-contained: it renders its own chrome to
// stderr, saves config 0600 (via SaveConfig, identical to the password path),
// and emits the UNCHANGED {ok, cloud_url, team_id} envelope for -o json/yaml. It
// returns nil on success; a *deviceAuthError on denial/expiry/timeout (→
// exitAuth); or a plain error on a transport/config failure (→ exitGeneric). The
// caller owns the exit-code mapping so the wizard can reuse this verbatim.
func runDeviceLoginFlow(out *writer, cfg *Config, base, clientName string) error {
	client := &cloudclient.Client{BaseURL: base}

	ds, err := client.DeviceStart(cloudCtx(), clientName)
	if err != nil {
		return fmt.Errorf("could not start browser login: %w", err)
	}

	renderDeviceBox(out, ds)

	// The complete URI embeds the code (prefilled approve form); fall back to the
	// bare page. This is what we open / the user copies.
	openURL := ds.VerificationURIComplete
	if openURL == "" {
		openURL = ds.VerificationURI
	}

	// On a real terminal, offer to open the browser — best-effort, NEVER fatal
	// (the boxed URL is already the deliverable; cloud_open_cmd.go's idiom). On a
	// non-tty (a forced --device in CI) we skip straight to polling.
	if out.isTTY {
		fmt.Fprint(out.stderr, "Press Enter to open your browser (or copy the URL above)… ")
		var discard string
		_, _ = fmt.Fscanln(os.Stdin, &discard) // best-effort; a bare Enter is fine
		if berr := browserOpener(openURL); berr != nil {
			out.errf("could not open a browser (%v) — copy the URL above", berr)
		}
	}

	// Poll spacing: honor the server's interval, fall back to devicePoll.
	interval := time.Duration(ds.Interval) * time.Second
	if interval <= 0 {
		interval = devicePoll
	}

	out.errf("Waiting for you to approve in the browser…")
	for i := 0; i < devicePollMax; i++ {
		status, perr := devicePollStep(out, cfg, client, base, ds.DeviceCode)
		if perr != nil {
			// Only a TRUE refusal aborts. classifyDevicePollError (inside the step)
			// already draws the terminal line: a *deviceAuthError is the user's
			// decision — they denied it or the code expired — and there is nothing to
			// wait for, so we return immediately with zero further polls. Anything
			// else is a TRANSIENT transport blip (a 500, a dropped connection); the
			// human is still at the browser and their approval has not been consulted,
			// so we back off and keep waiting — identical to how the one-shot
			// --device-poll maps the same error to a retryable exitGeneric. The
			// devicePollMax cap bounds the retries: an all-error server still
			// terminates via the timeout below, never spinning forever.
			if asDeviceAuthError(perr) {
				return perr
			}
			interval += devicePoll // widen the cadence on a transient failure
			if out.isTTY {
				fmt.Fprint(out.stderr, ".") // keep the heartbeat alive while we retry
			}
			deviceSleep(interval)
			continue
		}
		switch status {
		case cloudclient.DevicePollApproved:
			// devicePollStep persisted the session and emitted the success
			// surface — the flow is done.
			return nil
		case cloudclient.DevicePollSlowDown:
			// The control plane asked us to back off — widen the interval so a
			// too-eager loop stops tripping the poll rate-limit. Interval widening
			// lives HERE (the interactive caller owns cadence), not in the step.
			interval += devicePoll
		case cloudclient.DevicePollPending:
			// No decision yet — keep waiting.
		}
		if out.isTTY {
			fmt.Fprint(out.stderr, ".") // a lightweight progress heartbeat
		}
		deviceSleep(interval)
	}
	if out.isTTY {
		out.errf("")
	}
	return &deviceAuthError{msg: "timed out waiting for browser approval — run `bp login` again, or " + deviceEmailFallback}
}

// devicePollStep performs EXACTLY ONE device-poll against the control plane and,
// on approval, persists the session and emits the success surface. It is
// STATELESS — the caller owns the poll cadence (interval widening, heartbeat
// dots, the retry loop) — so BOTH the interactive runDeviceLoginFlow loop and the
// non-interactive `bp login --device-poll` one-shot drive a single poll from one
// body. It returns the DevicePollStatus on a non-terminal outcome (Pending /
// SlowDown / Approved) so the caller can act on it; a transport or terminal-
// refusal error is mapped through classifyDevicePollError (→ *deviceAuthError on a
// refusal). On DevicePollApproved it writes CloudURL/CloudToken/CloudTeam, saves
// config 0600 (byte-identical to the password path), and calls emitDeviceLoginSuccess
// BEFORE returning — the success surface stays INSIDE the step so the interactive
// caller's stored-token contract is unchanged.
func devicePollStep(out *writer, cfg *Config, client *cloudclient.Client, base, deviceCode string) (cloudclient.DevicePollStatus, error) {
	res, perr := client.DevicePoll(cloudCtx(), deviceCode)
	if perr != nil {
		return 0, classifyDevicePollError(perr)
	}
	if res.Status == cloudclient.DevicePollApproved {
		cfg.CloudURL = base
		cfg.CloudToken = res.Login.Token
		cfg.CloudTeam = res.Login.TeamID
		if serr := SaveConfig(cfg); serr != nil {
			return 0, fmt.Errorf("save config: %w", serr)
		}
		emitDeviceLoginSuccess(out, base, res.Login.TeamID)
	}
	return res.Status, nil
}

// runDeviceStartStep is the non-interactive FIRST leg of the split device login
// (`bp login --device-start`, BP-ONB-13). It mints ONE device-authorization code
// pair via DeviceStart and emits it as a single JSON envelope — device_code,
// user_code, verification_uri, verification_uri_complete, interval, expires_in —
// then returns exitOK WITHOUT polling. No box, no browser open, no blocking loop:
// a headless / agent wrapper surfaces the URL + code to the human itself and then
// drives approval with repeated `--device-poll`, owning the whole cadence.
func runDeviceStartStep(out *writer, base string) int {
	client := &cloudclient.Client{BaseURL: base}
	ds, err := client.DeviceStart(cloudCtx(), deviceClientName())
	if err != nil {
		return useError(out, "failed", "could not start browser login: "+err.Error(), exitGeneric)
	}
	emitDeviceEnvelope(out, map[string]any{
		"device_code":               ds.DeviceCode,
		"user_code":                 ds.UserCode,
		"verification_uri":          ds.VerificationURI,
		"verification_uri_complete": ds.VerificationURIComplete,
		"interval":                  ds.Interval,
		"expires_in":                ds.ExpiresIn,
	})
	return exitOK
}

// runDevicePollStep is the non-interactive SECOND leg (`bp login --device-poll
// <device_code>`, BP-ONB-13): it drives devicePollStep EXACTLY ONCE and returns —
// never a blocking 15-minute loop. The script owns the cadence (typically a shell
// `until bp login --device-poll $code; do sleep 5; done`), so the exit code is the
// contract: exitOK ONLY on approval (the loop terminates), a non-zero on pending /
// slow_down / error (the loop keeps polling). A single JSON envelope is ALWAYS
// emitted so a script that parses stdout has a faithful outcome:
//
//	approved   → devicePollStep already emitted {ok,cloud_url,team_id}; exitOK
//	pending    → {"status":"pending"}                                 ; exitGeneric
//	slow_down  → {"status":"slow_down"}                               ; exitGeneric
//	error      → {"status":"error","error":<msg>}                     ; exitAuth on a
//	             refusal (denied/expired), else exitGeneric
func runDevicePollStep(out *writer, cfg *Config, base, deviceCode string) int {
	client := &cloudclient.Client{BaseURL: base}
	status, err := devicePollStep(out, cfg, client, base, deviceCode)
	if err != nil {
		// A terminal refusal or a transport blip — devicePollStep did NOT persist
		// or emit success. Surface an error envelope and map the exit.
		exit := exitGeneric
		if asDeviceAuthError(err) {
			exit = exitAuth
		}
		emitDeviceEnvelope(out, map[string]any{"status": "error", "error": err.Error()})
		return exit
	}
	switch status {
	case cloudclient.DevicePollApproved:
		// devicePollStep already persisted the session and emitted its success
		// envelope/line — a single clean stdout doc — so we only return the exitOK
		// that terminates the caller's `until` loop.
		return exitOK
	case cloudclient.DevicePollSlowDown:
		emitDeviceEnvelope(out, map[string]any{"status": "slow_down"})
		return exitGeneric
	default: // DevicePollPending
		emitDeviceEnvelope(out, map[string]any{"status": "pending"})
		return exitGeneric
	}
}

// emitDeviceEnvelope writes payload as the single machine envelope the split
// device-login steps hand a script. It honours -o json / -o yaml via emitStructured
// and, on the human/table path, still renders JSON so the envelope is ALWAYS
// present on stdout (these steps have no meaningful human surface — they exist to
// be driven).
func emitDeviceEnvelope(out *writer, payload map[string]any) {
	if !out.emitStructured(payload) {
		out.renderJSON(payload)
	}
}

// emitDeviceLoginSuccess writes the SAME success surface a password login does:
// the {ok, cloud_url, team_id} envelope for machine consumers, else the human
// confirmation lines on stdout (runLoginCloud's tail, verbatim).
//
// It stops at the "logged in" confirmation and NO LONGER prints a next-step hint:
// the caller (runLoginCloud) drives finishLoginConnect right after, which
// auto-registers the fleet and lands the user in a working surface — the former
// dead-end "run 'bp barkparks'" line is gone (bp-login-ux W2). The wizard's
// cloudSetupDeviceLogin reuse is unaffected: it continues into cloudFleetPick.
func emitDeviceLoginSuccess(out *writer, base, teamID string) {
	if out.isTTY {
		out.errf("") // close the heartbeat dots line before the confirmation
	}
	if out.emitStructured(map[string]any{
		"ok":        true,
		"cloud_url": base,
		"team_id":   teamID,
	}) {
		return
	}
	out.outf("✓ logged in to %s", base)
	if teamID != "" {
		out.outf("  team: %s", teamID)
	}
}

// classifyDevicePollError maps a terminal poll error onto the CLI's exit scheme:
// a control-plane refusal the user can understand (they denied it, or the code
// expired) is an AUTH failure carrying a friendly retry hint; anything else (a
// transport blip, an unexpected code) stays a generic error. cloudError carries
// the control plane's code string verbatim, so a substring match is faithful.
func classifyDevicePollError(err error) error {
	m := err.Error()
	for _, code := range []string{"access_denied", "expired_token", "expired", "denied", "unauthorized"} {
		if strings.Contains(m, code) {
			return &deviceAuthError{msg: "browser login was denied or the code expired — run `bp login` again, or " + deviceEmailFallback}
		}
	}
	return fmt.Errorf("browser login failed: %w", err)
}

// renderDeviceBox paints the rounded verification box to stderr: the approve URL
// and the short code the user types, with the email fallback beneath. All chrome
// — never stdout — so `-o json` stays a single clean envelope.
func renderDeviceBox(out *writer, ds cloudclient.DeviceStartResp) {
	// Show the BARE page in the box (the user reads it and types the code); the
	// complete URI is only for the auto-open.
	url := ds.VerificationURI
	if url == "" {
		url = ds.VerificationURIComplete
	}

	var b strings.Builder
	b.WriteString(deviceBoxTitle.Render("Log in to Barkpark Cloud"))
	b.WriteString("\n\n")
	b.WriteString("Visit  " + deviceBoxURL.Render(url))
	b.WriteString("\nEnter code  " + deviceBoxCode.Render(ds.UserCode))

	out.errf("%s", deviceBoxBorder.Render(b.String()))
	out.errf("%s", deviceEmailFallback)
}

// deviceRequested reports whether runLoginCloud should take the device-link path
// rather than the password path. It engages when forced (--device) OR when the
// user supplied NO credential of any kind AND both streams are a genuine TTY (so
// there is a human to approve in a browser and nothing to prompt for). Every
// other combination — any credential input, a piped/CI invocation — falls
// through to the password path VERBATIM, preserving `bp login`'s backward
// compatibility (--email still prompts a password; BARKPARK_PASSWORD is unchanged).
func deviceRequested(device bool, email, password string) bool {
	if device {
		return true
	}
	noCreds := strings.TrimSpace(email) == "" &&
		password == "" &&
		os.Getenv("BARKPARK_PASSWORD") == ""
	return noCreds && deviceTTYCheck()
}

// asDeviceAuthError reports whether err is (or wraps) a deviceAuthError — the
// exitAuth vs exitGeneric discriminator for runLoginCloud.
func asDeviceAuthError(err error) bool {
	var ae *deviceAuthError
	return errors.As(err, &ae)
}
