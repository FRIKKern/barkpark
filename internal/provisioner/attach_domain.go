package provisioner

import (
	"context"
	"fmt"
	"net"
	"regexp"
	"strings"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// attachEnvFile is the env file deploy.sh sources for the app on every managed
// box (the same /opt/barkpark/.env the provision-time PHX_HOST/PHX_SCHEME steps
// write). The attach-domain flow merges the custom host's origin into
// BARKPARK_EXTRA_ORIGINS here so Phoenix check_origin admits it after a restart.
const attachEnvFile = "/opt/barkpark/.env"

// attachCaddyfilePath is the instance box's Caddyfile — the single-FQDN file the
// provision-time setup.CaddySteps wrote. The attach-domain flow APPENDS a second
// vhost for the custom host rather than rewriting the whole file, so the
// provision-time block (and any prior attached host) is never clobbered.
const attachCaddyfilePath = "/etc/caddy/Caddyfile"

// attachCustomHostRe is the PLATFORM custom-host shape (V1): exactly ONE DNS
// label under the platform zone (gyldendal.barkpark.cloud) — we own that DNS
// zone, so an A-record upsert is safe. The worker validates DEFENSIVELY
// against this even though the control plane already did: the custom host is
// interpolated into a Caddyfile and a shell script on the box, so a hostile
// value from a compromised/buggy control plane must abort HERE, before any
// side effect. Arbitrary customer domains ride the SEPARATE external path
// below (attachExternalHostRe + the resolution gate) — V2, this wave.
var attachCustomHostRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.barkpark\.cloud$`)

// attachDNSLabelRe is a single well-formed DNS label (the custom host minus the
// platform zone) — what the DNS seam upserts as the record Name.
var attachDNSLabelRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// attachExternalHostRe is the V2 EXTERNAL custom-host shape: an arbitrary
// customer-owned FQDN (barkpark.jarl.no) — TWO OR MORE well-formed RFC labels,
// lowercase. The same defensive posture as attachCustomHostRe: the value is
// interpolated into a Caddyfile and a shell script, so the regex admits ONLY
// dots, hyphens, and alphanumerics — every shell/Caddy metacharacter (space,
// quote, `$`, backtick, `;`, newline, unicode, …) is excluded by construction.
// Length caps ride separately: 63 per label (the regex) and 253 total
// (maxAttachHostLen).
var attachExternalHostRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)

// maxAttachHostLen is the RFC 1035 cap on a full domain name.
const maxAttachHostLen = 253

// attachNumericTLDRe rejects an all-digit final label — no real TLD is
// numeric, so anything matching is a bare-IP shape (203.0.113.9), which must
// never become a Caddy vhost with on-demand ACME.
var attachNumericTLDRe = regexp.MustCompile(`\.[0-9]+$`)

// externalAttachHost reports whether host rides the V2 EXTERNAL path: anything
// that is not under (or equal to) the platform zone. The platform apex itself
// returns true here and is then explicitly rejected by
// validateExternalAttachHost — it is never attachable either way.
func externalAttachHost(host string) bool {
	return !strings.HasSuffix(host, "."+Zone)
}

// validateExternalAttachHost is the fail-closed shape gate for a V2 external
// custom host. Same contract as the platform checks: any miss aborts before
// ANY side effect (no resolver call, no DNS write, no remote command).
func validateExternalAttachHost(host string) error {
	if host == Zone {
		return fmt.Errorf("attach-domain: custom_host %q is the platform apex itself — refusing before any side effect", host)
	}
	if len(host) > maxAttachHostLen {
		return fmt.Errorf("attach-domain: custom_host is %d chars, over the %d-char FQDN cap — refusing before any side effect", len(host), maxAttachHostLen)
	}
	if !attachExternalHostRe.MatchString(host) {
		return fmt.Errorf("attach-domain: custom_host %q is not a well-formed lowercase FQDN — refusing before any side effect", host)
	}
	if attachNumericTLDRe.MatchString(host) {
		return fmt.Errorf("attach-domain: custom_host %q has an all-numeric TLD (bare-IP shape) — refusing before any side effect", host)
	}
	return nil
}

// AttachDomainFunc points a custom host at one live box for a claimed
// attach-domain job: DNS A record → BARKPARK_EXTRA_ORIGINS merge + Caddy vhost
// on the box → caddy reload + app restart. Injected like DeprovisionFunc so the
// worker stays transport-only and tests drive it against fakes.
//
// IT HAS AN ORPHAN EDGE, and idempotence is not the property that decides it.
// Every step here IS idempotent (DNS upsert, guarded env merge, guarded vhost
// append), which is why this doc used to conclude "a re-run after a dropped
// succeed-report is a safe no-op — no orphan edge to guard." That reasoning
// answers "is re-running SAFE?" The orphan hazard asks a different question:
// "should this have run AT ALL?" An A-record upsert is perfectly idempotent and
// perfectly WRONG once the box is gone — re-running it a hundred times leaves
// exactly one record pointing at an address the provider will reassign to a
// stranger. Deprovision deletes the box FIRST, so a job still claimed when the
// teardown drains writes its record AFTER the by-value sweep that exists to
// prevent it; the record then has no box, and every orphan backstop in the fleet
// is keyed on a box (SweepOrphans selects barkpark-orphaned=true and cleans that
// box's DNS), so nothing can reach it. AttachDomainWith therefore guards the
// platform-DNS write with a box-liveness re-check before AND after the upsert.
type AttachDomainFunc func(ctx context.Context, spec AttachDomainSpec) error

// validateAttachDomainSpec is the fail-closed gate every attach-domain job
// passes BEFORE any side effect. The worker never trusts the control-plane
// payload: custom_host/dns_label reach a Caddyfile and a remote shell script,
// and ip reaches the SSH argv, so each is re-validated against the strict
// shapes here. Any miss aborts with NO DNS write and NO remote command.
//
// V2 split: a host under the platform zone keeps the V1 checks verbatim
// (single label + consistent dns_label/dns_zone halves for the A-record
// upsert). An EXTERNAL customer FQDN passes the well-formed-FQDN gate instead
// and must carry EMPTY DNS halves — the customer owns that zone, so a claim
// smuggling platform-DNS coordinates alongside an external host is
// inconsistent and aborts.
func validateAttachDomainSpec(spec AttachDomainSpec) error {
	if externalAttachHost(spec.CustomHost) {
		if err := validateExternalAttachHost(spec.CustomHost); err != nil {
			return err
		}
		if spec.DNSLabel != "" || spec.DNSZone != "" {
			return fmt.Errorf("attach-domain: external custom_host %q carries platform DNS halves (%q/%q) — inconsistent claim", spec.CustomHost, spec.DNSLabel, spec.DNSZone)
		}
	} else {
		if !attachCustomHostRe.MatchString(spec.CustomHost) {
			return fmt.Errorf("attach-domain: custom_host %q is not a single label under %s — refusing before any side effect", spec.CustomHost, Zone)
		}
		if !attachDNSLabelRe.MatchString(spec.DNSLabel) {
			return fmt.Errorf("attach-domain: dns_label %q is not a valid DNS label — refusing before any side effect", spec.DNSLabel)
		}
		if spec.DNSZone != Zone {
			return fmt.Errorf("attach-domain: dns_zone %q is not the platform zone %s for platform host %q", spec.DNSZone, Zone, spec.CustomHost)
		}
		if spec.CustomHost != spec.DNSLabel+"."+spec.DNSZone {
			return fmt.Errorf("attach-domain: custom_host %q does not equal dns_label+dns_zone (%q.%q) — inconsistent claim", spec.CustomHost, spec.DNSLabel, spec.DNSZone)
		}
	}
	if net.ParseIP(spec.IP) == nil {
		return fmt.Errorf("attach-domain: ip %q is not a valid IP address — refusing before any side effect", spec.IP)
	}
	if spec.AppPort < 1 || spec.AppPort > 65535 {
		return fmt.Errorf("attach-domain: app_port %d is not a valid port", spec.AppPort)
	}
	return nil
}

// renderCustomHostVhost renders the Caddy vhost block APPENDED for the custom
// host, mirroring the provision-time caddyfileTemplate shape (site block keyed
// on the host + reverse_proxy + the branded maintenance handler) with ONE
// deliberate difference: `tls { on_demand }`. Issuance for an attached host is
// on-demand and gated by the control plane's /v1/tls/ask endpoint
// (Registry.domain_registered? must approve the host), so a cert is only
// obtained for hosts the control plane vouches for.
func renderCustomHostVhost(host string, appPort int) string {
	var sb strings.Builder
	sb.WriteString("\n# Managed by barkpark-provisioner (attach-domain) — custom host " + host + ".\n")
	sb.WriteString("# On-demand TLS is gated by the control plane's /v1/tls/ask. Do not edit by hand.\n")
	sb.WriteString(host + " {\n")
	sb.WriteString("\ttls {\n")
	sb.WriteString("\t\ton_demand\n")
	sb.WriteString("\t}\n")
	sb.WriteString(fmt.Sprintf("\treverse_proxy 127.0.0.1:%d\n", appPort))
	sb.WriteString(caddyfile.MaintenanceHandler("\t"))
	sb.WriteString("}\n")
	return sb.String()
}

// mergeExtraOriginStep renders the idempotent "merge https://<host> into
// BARKPARK_EXTRA_ORIGINS" step for the app env file. It follows the
// secrets-install rewrite model (grep -v strip + printf append + mv — portable,
// no sed -i) rather than setEnvVarStep's replace-whole-value, because the value
// is a comma-separated LIST that must be extended, not overwritten: an existing
// origin (another attached host) is preserved, and a re-run with the origin
// already present changes nothing. The interpolated origin is safe by
// construction — validateAttachDomainSpec pinned the host to [a-z0-9.-].
func mergeExtraOriginStep(origin, envFile string) cloud.CaddyStep {
	script := strings.Join([]string{
		"cur=$(grep '^BARKPARK_EXTRA_ORIGINS=' " + envFile + " 2>/dev/null | head -n1 | cut -d= -f2- || true)",
		"case \",$cur,\" in",
		"*,'" + origin + "',*) : ;;",
		"*)",
		"  if [ -n \"$cur\" ]; then new=\"$cur," + origin + "\"; else new='" + origin + "'; fi",
		"  tmp=$(mktemp)",
		"  grep -v '^BARKPARK_EXTRA_ORIGINS=' " + envFile + " > \"$tmp\" 2>/dev/null || true",
		"  printf 'BARKPARK_EXTRA_ORIGINS=%s\\n' \"$new\" >> \"$tmp\"",
		"  mv \"$tmp\" " + envFile,
		"  ;;",
		"esac",
	}, "\n")
	argv := []string{"bash", "-lc", script}
	return cloud.CaddyStep{
		Title: "merge " + origin + " into BARKPARK_EXTRA_ORIGINS in the app env (Phoenix check_origin)",
		Cmd:   script,
		Argv:  argv,
	}
}

// appendCustomVhostStep renders the idempotent "append the custom-host vhost to
// the Caddyfile" step: a guarded heredoc'd `tee -a` (the writeFileStep idiom,
// append mode) that is SKIPPED when the host's site block already exists, so a
// re-run never duplicates the block. The single-quoted heredoc delimiter keeps
// the vhost body literal (no shell/var expansion).
func appendCustomVhostStep(host string, appPort int, caddyfilePath string) cloud.CaddyStep {
	vhost := renderCustomHostVhost(host, appPort)
	script := "if ! grep -qF '" + host + " {' " + caddyfilePath + " 2>/dev/null; then tee -a " + caddyfilePath + " > /dev/null << 'BPEOF'\n" + vhost + "BPEOF\nfi"
	argv := []string{"bash", "-lc", script}
	return cloud.CaddyStep{
		Title: "append the Caddy vhost for " + host + " (tls on_demand → 127.0.0.1:" + fmt.Sprintf("%d", appPort) + ")",
		Cmd:   "grep -qF '" + host + " {' " + caddyfilePath + " || tee -a " + caddyfilePath + " << 'BPEOF' … BPEOF",
		Argv:  argv,
	}
}

// caddyValidateReloadStep validates the Caddyfile BEFORE reloading — a
// malformed config must never be handed to a live Caddy — then enables +
// reloads exactly like the provision-time caddyReloadStep (`enable --now` is
// idempotent and covers a cold start; `reload` re-reads without dropping
// connections).
func caddyValidateReloadStep(caddyfilePath string) cloud.CaddyStep {
	script := "caddy validate --config " + caddyfilePath + " && systemctl enable --now caddy && systemctl reload caddy"
	argv := []string{"bash", "-lc", script}
	return cloud.CaddyStep{
		Title: "validate + reload Caddy (apply the new custom-host vhost)",
		Cmd:   script,
		Argv:  argv,
	}
}

// instanceRestartStep restarts the Barkpark app so it re-reads the env —
// Phoenix reads check_origin once at boot, so without this restart the merged
// BARKPARK_EXTRA_ORIGINS never takes effect and LiveView 403s the new host
// (the same click-dead footgun the provision-time barkparkRestartStep guards).
func instanceRestartStep() cloud.CaddyStep {
	argv := []string{"bash", "-lc", "systemctl restart barkpark"}
	return cloud.CaddyStep{
		Title: "restart Barkpark (pick up BARKPARK_EXTRA_ORIGINS — LiveView check_origin)",
		Cmd:   "systemctl restart barkpark",
		Argv:  argv,
	}
}

// attachDomainSteps is the ordered remote plan for one VALIDATED attach-domain
// spec — env merge, vhost append, caddy validate+reload, app restart. Pure (no
// I/O): tests execute the rendered scripts against temp files to prove the
// idempotence guards, and DefaultAttachDomain runs them over the SSH seam.
// Callers MUST have passed spec through validateAttachDomainSpec first — the
// scripts interpolate spec.CustomHost.
func attachDomainSteps(spec AttachDomainSpec, envFile, caddyfilePath string) []cloud.CaddyStep {
	origin := "https://" + spec.CustomHost
	return []cloud.CaddyStep{
		mergeExtraOriginStep(origin, envFile),
		appendCustomVhostStep(spec.CustomHost, spec.AppPort, caddyfilePath),
		caddyValidateReloadStep(caddyfilePath),
		instanceRestartStep(),
	}
}

// AttachDomainWith attaches spec.CustomHost to the box at spec.IP via the
// seams' DNS/resolver + per-host runner:
//
//  1. DEFENSIVE validation (validateAttachDomainSpec) — a hostile/inconsistent
//     claim payload aborts before ANY side effect.
//  2. DNS, split by host kind (V2):
//     - PLATFORM host: re-check that a managed box still holds spec.ip, upsert
//     the A record <dns_label>.<dns_zone> → ip (create-or-replace,
//     idempotent) — we own the zone, pointing it IS the attach — then re-check
//     LIVENESS AGAIN and delete the record if the box vanished mid-write.
//     Fail-closed on both, exactly like the external branch's resolve gate.
//     - EXTERNAL host: NO platform upsert (the customer owns DNS). Instead,
//     re-verify via the system resolver that the FQDN ALREADY resolves to
//     the box — the ownership moat, enforced worker-side too because the
//     worker cannot trust the control plane's pre-check. Fail-closed: a
//     resolver error or a mismatch aborts with no remote command.
//  3. SSH (identical for both kinds): merge https://<custom_host> into
//     BARKPARK_EXTRA_ORIGINS, append the on-demand-TLS Caddy vhost, validate +
//     reload Caddy, restart the app — every remote command through the
//     StepRunner seam, each step idempotent.
//
// A step failure aborts the remainder and fails the job. A platform DNS record
// already upserted when a LATER (SSH) step fails is acceptable residue — but
// only because of the gate above, and the reason is worth stating precisely,
// because the previous version of this comment got it wrong. It is NOT
// acceptable "because the upsert is idempotent": idempotence answers "is
// re-running safe?", and the orphan hazard asks "should this have run at all?".
// It is acceptable because the record points at a box we verified is LIVE, so it
// is reachable by both box-keyed backstops — the deprovision teardown's
// by-value sweep, and SweepOrphans via the barkpark-orphaned label — and a retry
// re-points it. Strip the liveness gate and the same residue becomes an
// unreachable orphan: an A record whose box is gone carries no label and no
// owner, so nothing but a zone-level audit can ever find it.
func AttachDomainWith(ctx context.Context, seams Seams, spec AttachDomainSpec) error {
	if err := validateAttachDomainSpec(spec); err != nil {
		return err
	}

	if externalAttachHost(spec.CustomHost) {
		lookup := seams.LookupHost
		if lookup == nil {
			lookup = func(ctx context.Context, host string) ([]string, error) {
				return net.DefaultResolver.LookupHost(ctx, host)
			}
		}
		addrs, err := lookup(ctx, spec.CustomHost)
		if err != nil {
			return fmt.Errorf("attach-domain %s: resolve: %w — refusing before any side effect (fail closed)", spec.CustomHost, err)
		}
		if !containsAddr(addrs, spec.IP) {
			return fmt.Errorf("attach-domain %s: the host does not resolve to the box %s (observed %v) — point the domain first", spec.CustomHost, spec.IP, addrs)
		}
	} else {
		if seams.DNS == nil {
			return fmt.Errorf("provisioner: a DNSProvider must be set to attach a platform-zone domain")
		}
		if seams.Provider == nil {
			return fmt.Errorf("provisioner: a CloudProvider must be set to attach a platform-zone domain — the box-liveness re-check is not optional")
		}

		// BEFORE the write: deprovision deletes the BOX first and only then sweeps
		// its records by value, so a job still claimed when a teardown drains would
		// otherwise publish its record AFTER the sweep meant to prevent it. Refuse
		// to point the zone at an address no box holds any more.
		live, err := boxHoldsIP(ctx, seams.Provider, spec.IP)
		if err != nil {
			return fmt.Errorf("attach-domain %s: box liveness re-check: %w — refusing before any side effect (fail closed)", spec.CustomHost, err)
		}
		if !live {
			return fmt.Errorf("attach-domain %s: no managed box holds %s any more — the instance was deprovisioned while this job was in flight; refusing to point DNS at a freed address (fail closed)", spec.CustomHost, spec.IP)
		}

		rec := cloud.Record{Zone: spec.DNSZone, Name: spec.DNSLabel, Type: "A", Value: spec.IP}
		if err := seams.DNS.UpsertRecord(ctx, rec); err != nil {
			return fmt.Errorf("attach-domain %s: dns upsert: %w", spec.CustomHost, err)
		}

		// AFTER the write: the orphan edge, and the half the pre-check cannot
		// cover. The box is live when consulted and can be gone a moment later —
		// the deprovision job may already be CLAIMED, past every control-plane
		// refusal. So re-read liveness and, if the box went away underneath us,
		// delete the record we just created. This is the money-edge discipline
		// ProvisionWith already uses for a box the control plane never learned
		// about, with DeleteRecord as the verb instead of provider.Delete.
		stillLive, rerr := boxHoldsIP(ctx, seams.Provider, spec.IP)
		if rerr != nil {
			return fmt.Errorf("attach-domain %s: wrote the A record but could not re-confirm a box still holds %s: %w — failing the job so the record is reviewed rather than assumed good", spec.CustomHost, spec.IP, rerr)
		}
		if !stillLive {
			fqdn := cloud.Fqdn(spec.DNSLabel, spec.DNSZone)
			if derr := seams.DNS.DeleteRecord(ctx, spec.DNSZone, spec.DNSLabel, "A"); derr != nil {
				// The loudest thing this process will ever say: no box-keyed
				// backstop can reach this record, so this error is the ONLY
				// artefact naming it. Carry the FQDN and the address.
				return fmt.Errorf("attach-domain %s: ORPHANED A RECORD %s → %s: the box was deprovisioned mid-write and deleting the record again failed: %w — delete it by hand; no box-keyed backstop can reach a record whose box is gone", spec.CustomHost, fqdn, spec.IP, derr)
			}
			return fmt.Errorf("attach-domain %s: the box at %s was deprovisioned while the A record was being written — %s has been deleted again (fail closed)", spec.CustomHost, spec.IP, fqdn)
		}
	}

	runnerFor := seams.RunnerFor
	if runnerFor == nil {
		// The same production default the warm-pool chain falls back to: a per-host
		// SSH runner for the box's IP.
		runnerFor = func(host string) cloud.StepRunner { return cloud.NewSSHStepRunner(host) }
	}
	runner := runnerFor(spec.IP)
	for _, s := range attachDomainSteps(spec, attachEnvFile, attachCaddyfilePath) {
		if err := runner.Run(ctx, s); err != nil {
			return fmt.Errorf("attach-domain %s: %w", spec.CustomHost, err)
		}
	}
	return nil
}

// boxHoldsIP reports whether ANY managed box in the fleet still holds ip. It is
// the attach path's liveness gate, and it reads the fleet by IP because that is
// the only handle an attach-domain claim carries — the payload names the address
// (spec.ip), never the server name, so provider.IP(name) is not available here.
//
// It deliberately uses only the CORE CloudProvider contract (List), so every
// provider satisfies it and no optional capability can be missing at the moment
// the guard is needed. An error is never read as "absent": the callers fail
// closed on it, because "the fleet is unreadable" and "the box is gone" must not
// collapse into the same answer.
func boxHoldsIP(ctx context.Context, p cloud.CloudProvider, ip string) (bool, error) {
	servers, err := p.List(ctx)
	if err != nil {
		return false, err
	}
	for _, s := range servers {
		if s.IP == ip {
			return true, nil
		}
	}
	return false, nil
}

// containsAddr reports whether want is among the RESOLVED addresses, compared
// as parsed IPs so textual variants of the same address ("::1" vs
// "0:0:0:0:0:0:0:1") never cause a false mismatch.
func containsAddr(addrs []string, want string) bool {
	wantIP := net.ParseIP(want)
	if wantIP == nil {
		return false
	}
	for _, a := range addrs {
		if ip := net.ParseIP(a); ip != nil && ip.Equal(wantIP) {
			return true
		}
	}
	return false
}

// DefaultAttachDomain returns an AttachDomainFunc bound to seams — the value the
// Worker calls per attach-domain job. Tests bind it to the fakes; main() binds
// it to the real Cloud DNS + per-host SSH runner (the SAME seams as
// provision/deprovision).
func DefaultAttachDomain(seams Seams) AttachDomainFunc {
	return func(ctx context.Context, spec AttachDomainSpec) error {
		return AttachDomainWith(ctx, seams, spec)
	}
}
