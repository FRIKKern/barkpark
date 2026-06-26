package setup

import (
	"bytes"
	"fmt"
	"strings"
	"text/template"
)

// CaddyOpts parameterises the Caddy/TLS provisioning step generator for ONE
// managed barkpark.cloud server. Name is the per-server subdomain label (e.g.
// "acme" → acme.barkpark.cloud); Domain is the apex the label hangs under
// ("barkpark.cloud"); AppPort is the local port Phoenix listens on (4000).
//
// YAGNI: exactly one server, one subdomain, automatic ACME. No multi-domain,
// no custom certs, no load-balancing — those are explicitly out of scope.
type CaddyOpts struct {
	Name    string // per-server label, e.g. "acme"
	Domain  string // apex, e.g. "barkpark.cloud"
	AppPort int    // local app port, e.g. 4000
}

// fqdn renders the full public hostname Caddy fronts: "<name>.<domain>".
func (o CaddyOpts) fqdn() string {
	return o.Name + "." + o.Domain
}

// appEnvFile is the env file deploy.sh sources for the app (mirrors deploy.sh's
// $APP_DIR/.env at /opt/barkpark/.env). The PHX_HOST / PHX_SCHEME step writes
// here so a restart picks up the public hostname LiveView's check_origin needs.
const appEnvFile = "/opt/barkpark/.env"

// caddyfileTemplate renders /etc/caddy/Caddyfile for ONE managed server. The
// site block keys on the FQDN, which is what arms Caddy's default-on ACME: once
// public DNS points <fqdn> at this box, Caddy issues + renews the cert with no
// further config. reverse_proxy hands every request to the local app port; the
// app itself stays bound to localhost (ufw denies :4000 publicly — see the
// caddySteps generator). Real issuance is deferred to cloud-15 (a real
// DNS-pointed domain); this template only renders the config that WILL issue.
const caddyfileTemplate = `# Managed by bp setup (cloud-4) — barkpark.cloud automatic TLS.
# Caddy's default ACME issues + renews the cert for {{.FQDN}} automatically
# once public DNS points {{.FQDN}} at this host. Do not edit by hand.
{{.FQDN}} {
	reverse_proxy localhost:{{.AppPort}}
}
`

// caddyfileData is the template binding — the FQDN and the app port. Derived
// from CaddyOpts so the template never reaches into struct internals.
type caddyfileData struct {
	FQDN    string
	AppPort int
}

// renderCaddyfile renders the Caddyfile bytes for opts. It is pure (no I/O), so
// tests assert the exact rendered config without a box. An invalid opts set
// (empty name/domain or a non-positive port) is a programmer error and surfaces
// as an error rather than a half-rendered file.
func renderCaddyfile(opts CaddyOpts) (string, error) {
	if strings.TrimSpace(opts.Name) == "" {
		return "", fmt.Errorf("renderCaddyfile: Name is required (the per-server subdomain label, e.g. \"acme\")")
	}
	if strings.TrimSpace(opts.Domain) == "" {
		return "", fmt.Errorf("renderCaddyfile: Domain is required (the apex, e.g. \"barkpark.cloud\")")
	}
	if opts.AppPort <= 0 {
		return "", fmt.Errorf("renderCaddyfile: AppPort must be a positive port (e.g. 4000), got %d", opts.AppPort)
	}
	tmpl, err := template.New("caddyfile").Parse(caddyfileTemplate)
	if err != nil {
		return "", fmt.Errorf("renderCaddyfile: parse template: %w", err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, caddyfileData{FQDN: opts.fqdn(), AppPort: opts.AppPort}); err != nil {
		return "", fmt.Errorf("renderCaddyfile: execute template: %w", err)
	}
	return buf.String(), nil
}

// caddySteps returns the ordered Caddy/TLS provisioning steps for ONE managed
// barkpark.cloud server. Each step mirrors provision.go's idiom exactly: a human
// Title, a copy-pasteable Cmd rendered via shJoin, and the resolved Argv a real
// run execs (Argv[0] is the binary, the rest its args). The five steps are:
//
//  1. install Caddy from the official apt repo (the documented Debian/Ubuntu
//     install) — keyring + sources.list + apt-get install -y caddy.
//  2. write the rendered Caddyfile to /etc/caddy/Caddyfile (reverse_proxy →
//     localhost:<port>, automatic ACME on <fqdn>).
//  3. set PHX_HOST=<fqdn> + PHX_SCHEME=https in the app .env idempotently
//     (grep-then-append/replace, mirroring deploy.sh's BARKPARK_PLUGINS pattern)
//     — the LiveView-critical pair: a wrong PHX_HOST 403s /live/websocket.
//  4. reload Caddy so it picks up the new site block (enable first so a fresh
//     box also starts it on boot).
//  5. close the app port publicly — ufw deny <port>; only :443 is exposed, the
//     app stays reachable only via Caddy on localhost.
//
// caddySteps NEVER issues a cert and NEVER touches a real box — it only builds
// the plan. Real ACME issuance needs a DNS-pointed domain (HUMAN task cloud-15).
// A later task (cloud-6) wires these into the go-live sequence; this generator
// is standalone and does not alter deploy.go's existing flow.
//
// If renderCaddyfile rejects opts (bad name/domain/port), caddySteps falls back
// to an empty rendered Caddyfile in the write step so the returned slice is
// always well-formed; callers that care validate opts up front (the build path
// in cloud-6 will). The render error is intentionally not surfaced here to keep
// the generator total — provision.go's step builders are likewise total.
func caddySteps(opts CaddyOpts) []step {
	fqdn := opts.fqdn()
	caddyfile, _ := renderCaddyfile(opts)

	return []step{
		caddyInstallStep(),
		writeFileStep(
			"write the Caddyfile (reverse_proxy → localhost:"+fmt.Sprintf("%d", opts.AppPort)+", automatic TLS for "+fqdn+")",
			"/etc/caddy/Caddyfile",
			caddyfile,
		),
		setEnvVarStep("set PHX_HOST="+fqdn+" in the app env (LiveView check_origin)", "PHX_HOST", fqdn),
		setEnvVarStep("set PHX_SCHEME=https in the app env (LiveView check_origin)", "PHX_SCHEME", "https"),
		caddyReloadStep(),
		ufwDenyAppPortStep(opts.AppPort),
	}
}

// caddyInstallStep installs Caddy from its official apt repository — the
// documented Debian/Ubuntu path (keyring + sources.list, apt-get update, then
// `apt-get install -y caddy`). It is one shell beat: a single `bash -lc` of the
// documented script so the keyring/sources/install run atomically as a unit
// (the rendered Cmd shows the same line the operator would paste).
func caddyInstallStep() step {
	script := strings.Join([]string{
		"apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl",
		"curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg",
		"curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list",
		"apt-get update",
		"apt-get install -y caddy",
	}, " && ")
	argv := []string{"bash", "-lc", script}
	return step{
		Title: "install Caddy (official apt repo)",
		Cmd:   shJoin(argv),
		Argv:  argv,
	}
}

// caddyReloadStep enables + reloads Caddy so a fresh box starts it on boot and
// an already-running Caddy picks up the new /etc/caddy/Caddyfile site block.
// `systemctl reload caddy` re-reads the config without dropping connections;
// the preceding `enable --now` is idempotent and covers the cold-start case.
func caddyReloadStep() step {
	script := "systemctl enable --now caddy && systemctl reload caddy"
	argv := []string{"bash", "-lc", script}
	return step{
		Title: "reload Caddy (enable on boot + apply the new Caddyfile)",
		Cmd:   shJoin(argv),
		Argv:  argv,
	}
}

// ufwDenyAppPortStep closes the app port to the public — only :443 is exposed,
// the app stays reachable only over localhost via Caddy's reverse_proxy. `ufw
// deny <port>` is idempotent (a duplicate rule is a no-op in ufw).
func ufwDenyAppPortStep(port int) step {
	argv := []string{"ufw", "deny", fmt.Sprintf("%d", port)}
	return step{
		Title: fmt.Sprintf("close public access to the app port (ufw deny %d — only :443 is public)", port),
		Cmd:   shJoin(argv),
		Argv:  argv,
	}
}

// writeFileStep renders a step that writes content to path on the remote box via
// a heredoc'd `tee` — `tee <path> > /dev/null << 'BPEOF' … BPEOF`. The single-
// quoted delimiter makes the body literal (no shell/var expansion), so a
// Caddyfile with `{` / `}` lands byte-for-byte. The rendered Cmd shows the
// heredoc form; the Argv runs it through `bash -lc`.
func writeFileStep(title, path, content string) step {
	heredoc := "tee " + path + " > /dev/null << 'BPEOF'\n" + content
	if !strings.HasSuffix(heredoc, "\n") {
		heredoc += "\n"
	}
	heredoc += "BPEOF"
	argv := []string{"bash", "-lc", heredoc}
	return step{
		Title: title,
		Cmd:   "tee " + path + " << 'BPEOF' … BPEOF",
		Argv:  argv,
	}
}

// setEnvVarStep renders an idempotent "set KEY=VALUE in the app .env" step,
// mirroring deploy.sh's BARKPARK_PLUGINS pattern exactly: if a `^KEY=` line
// exists, sed-replace it in place; otherwise append. Either way the value is
// present-and-correct after the step, so re-running the go-live sequence never
// duplicates the line. Run through `bash -lc` for the grep/sed conditional.
func setEnvVarStep(title, key, value string) step {
	line := key + "=" + value
	script := fmt.Sprintf(
		"if grep -q '^%s=' %s; then sed -i 's|^%s=.*|%s|' %s; else echo '%s' >> %s; fi",
		key, appEnvFile,
		key, line, appEnvFile,
		line, appEnvFile,
	)
	argv := []string{"bash", "-lc", script}
	return step{
		Title: title,
		Cmd:   shJoin(argv),
		Argv:  argv,
	}
}
