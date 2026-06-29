// Package cloud is the provider seam for host provisioning. It extracts the
// hcloud (and, later, az) shell-out that `bp setup --target provision` performs
// today into a small CloudProvider interface with two implementations:
//
//   - HcloudProvider — the real impl. It builds the SAME argv `internal/cli/setup`
//     builds today (`hcloud server create --name … --type … --image … --location
//     … --ssh-key …`, `hcloud server ip <name>`) and shells out via the same
//     os/exec mechanism, reading auth from HCLOUD_TOKEN / an active `hcloud
//     context` exactly as before.
//   - FakeProvider — an in-memory map. Create assigns a deterministic fake IP and
//     id; IP/Delete/List operate purely on the map. No network, no Hetzner spend.
//     This is what every future provisioning test runs against.
//
// The seam mirrors the package's existing inject-an-interface, fake-in-tests
// idiom (see setup.ConfigStore + its in-memory test store). It is deliberately
// minimal — Create/IP/Delete/List, nothing more (YAGNI: no retries, no
// pagination, no extra providers yet).
package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Provider slugs the cloud seam understands. Only hetzner is wired to a real
// implementation here; the az/x86 path is a later task.
const (
	ProviderHetzner = "hetzner"
)

// Labels every managed box carries. ManagedLabel is stamped at create time on
// EVERY box (harmless on the happy path) so the fleet is identifiable; it is the
// fence SweepOrphans never crosses — a managed-but-not-orphaned box is left
// alone. OrphanedLabel is set ONLY in the teardown path, after the worker has
// already decided the box must die but provider.Delete persistently failed; it
// is the safe signal SweepOrphans deletes on, because a box only ever gets it
// once the worker meant to tear it down. FQDNLabel records the box's public FQDN
// so SweepOrphans can also delete the stranded DNS record.
//
// Hetzner label values must be ≤63 chars and match [A-Za-z0-9._-] (an empty
// value is allowed); a key may be prefixed with a DNS subdomain. The FQDN we
// store (e.g. acme-12.barkpark.cloud) fits both constraints.
const (
	ManagedLabelKey  = "barkpark-managed"
	OrphanedLabelKey = "barkpark-orphaned"
	FQDNLabelKey     = "barkpark-fqdn"
	managedLabelVal  = "true"
	orphanedLabelVal = "true"
)

// ServerSpec is the declarative description of the host to create. The field
// values map 1:1 onto the hcloud create flags: Name → --name, ServerType →
// --type, Image → --image, Region → --location.
type ServerSpec struct {
	Name       string
	Region     string
	ServerType string
	Image      string
}

// Server is a provisioned host as the provider reports it back: a provider id,
// the name it was created under, its public IPv4 (empty until known), and the
// labels the provider records on it. Labels is populated by the label-aware list
// path (ListByLabel); the plain List leaves it nil (YAGNI — only the orphan
// sweep reads labels back).
type Server struct {
	ID     string
	Name   string
	IP     string
	Labels map[string]string
}

// CloudProvider is the provisioning seam. A real impl shells out to a provider
// CLI; the fake keeps everything in memory. The four methods are the whole API
// the setup flow needs — create a host, read its IP, delete it, list them.
type CloudProvider interface {
	Create(ctx context.Context, spec ServerSpec) (Server, error)
	IP(ctx context.Context, name string) (string, error)
	Delete(ctx context.Context, name string) error
	List(ctx context.Context) ([]Server, error)
}

// ServerLabeler is the OPTIONAL capability a provider advertises when it can add
// a label to an existing box. It is kept OFF the core CloudProvider contract
// (which stays Create/IP/Delete/List) so a minimal/older provider needn't grow
// it; the teardown path type-asserts for it and best-effort labels the orphan
// when present. Both HcloudProvider and FakeProvider implement it.
type ServerLabeler interface {
	LabelServer(ctx context.Context, name, key, val string) error
}

// LabelLister is the OPTIONAL capability a provider advertises when it can list
// boxes carrying a given label. SweepOrphans uses it to find boxes labeled
// barkpark-orphaned=true. Off the core contract for the same YAGNI reason as
// ServerLabeler. Both HcloudProvider and FakeProvider implement it.
type LabelLister interface {
	ListByLabel(ctx context.Context, key, val string) ([]Server, error)
}

// DefaultSpec returns the region/type/image fallbacks for a provider so a bare
// `--provider hetzner` still renders a complete spec. Name is left empty for the
// caller to fill. An unknown provider yields a zero spec.
//
// The hetzner default is cx23/nbg1/ubuntu-22.04 — the cheapest AVAILABLE type
// (€5.49/mo). It deliberately is NOT cax11: ARM (cax) is entirely out of stock
// right now and the cpx line is being retired, so a cax/cpx default hard-fails
// on a real account. BARKPARK_SERVER_TYPE / BARKPARK_SERVER_LOCATION override
// the type/location, so when ARM stock returns `BARKPARK_SERVER_TYPE=cax11`
// flips the default back without a code change.
func DefaultSpec(provider string) ServerSpec {
	switch provider {
	case ProviderHetzner:
		spec := ServerSpec{Region: "nbg1", ServerType: "cx23", Image: "ubuntu-22.04"}
		if t := strings.TrimSpace(os.Getenv("BARKPARK_SERVER_TYPE")); t != "" {
			spec.ServerType = t
		}
		if loc := strings.TrimSpace(os.Getenv("BARKPARK_SERVER_LOCATION")); loc != "" {
			spec.Region = loc
		}
		// BARKPARK_SERVER_IMAGE points instances at a baked warm-pool snapshot
		// (Barkpark pre-installed) instead of bare ubuntu-22.04 — set it to the
		// Hetzner snapshot ID so go-lives boot a ready Barkpark host.
		if img := strings.TrimSpace(os.Getenv("BARKPARK_SERVER_IMAGE")); img != "" {
			spec.Image = img
		}
		return spec
	default:
		return ServerSpec{}
	}
}

// sshKeyLister lists the account's ssh-key names, one per line, via
// `hcloud ssh-key list -o columns=name -o noheader`. It is a package var so a
// test can override it without shelling out to hcloud.
var sshKeyLister = func(ctx context.Context) ([]string, error) {
	out, err := runCapture(ctx, "hcloud", "ssh-key", "list", "-o", "columns=name", "-o", "noheader")
	if err != nil {
		return nil, fmt.Errorf("hcloud ssh-key list: %w: %s", err, strings.TrimSpace(out))
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names, nil
}

// resolveSSHKey resolves the ssh-key NAME passed to `hcloud server create`. A
// real account's key is named per-account (e.g. "barkpark-indx"), so a hardcoded
// "barkpark" default fails with "ssh key not found". Resolution order:
//
//   - BARKPARK_SSH_KEY when set → use it verbatim.
//   - else list the account's keys via sshKeyLister; if EXACTLY ONE exists, use
//     its name (the unambiguous common case).
//   - else a clear error telling the operator to set BARKPARK_SSH_KEY, naming
//     how many keys were found (0 or N>1 — both are ambiguous to auto-select).
func resolveSSHKey(ctx context.Context) (string, error) {
	if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY")); k != "" {
		return k, nil
	}
	keys, err := sshKeyLister(ctx)
	if err != nil {
		return "", fmt.Errorf("set BARKPARK_SSH_KEY: could not list ssh keys: %w", err)
	}
	if len(keys) == 1 {
		return keys[0], nil
	}
	return "", fmt.Errorf("set BARKPARK_SSH_KEY: found %d ssh keys (need exactly one to auto-select)", len(keys))
}

// hcloudCreateArgv builds the exact argv `hcloud server create` execs. It is a
// PURE function — the resolved ssh-key NAME is passed in (resolveSSHKey does the
// impure work upstream) so a test can assert the argv without invoking hcloud.
// Flag order: name, type, image, location, ssh-key, label. Every created box is
// stamped barkpark-managed=true so the fleet is identifiable (harmless on the
// happy path; the fence the orphan sweep never crosses).
func hcloudCreateArgv(spec ServerSpec, sshKey string) []string {
	return []string{
		"hcloud", "server", "create",
		"--name", spec.Name,
		"--type", spec.ServerType,
		"--image", spec.Image,
		"--location", spec.Region,
		"--ssh-key", sshKey,
		"--label", ManagedLabelKey + "=" + managedLabelVal,
	}
}

// HetznerCandidates is the ordered resilience ladder CreateWithFallback walks
// when the preferred type/location is sold out. It PRESERVES base.Name and
// base.Image and varies only type/location, deduping any candidate equal to
// base. The cx/cpx fallbacks are all currently in stock.
//
// NOTE: ARM (cax) is currently out of stock; when it returns, set
// BARKPARK_SERVER_TYPE=cax11 and DefaultSpec leads with ARM, so the ladder's
// first (base) entry is the ARM type and the cx/cpx entries become the fallback.
func HetznerCandidates(base ServerSpec) []ServerSpec {
	ladder := []ServerSpec{
		base,
		{Name: base.Name, Region: "fsn1", ServerType: "cx23", Image: base.Image},
		{Name: base.Name, Region: "hel1", ServerType: "cx23", Image: base.Image},
		{Name: base.Name, Region: "nbg1", ServerType: "cx33", Image: base.Image},
		{Name: base.Name, Region: "fsn1", ServerType: "cpx22", Image: base.Image},
	}
	out := make([]ServerSpec, 0, len(ladder))
	out = append(out, base)
	for _, c := range ladder[1:] {
		if c == base {
			continue // dedupe: skip a candidate identical to base
		}
		out = append(out, c)
	}
	return out
}

// CreateWithFallback tries each HetznerCandidates spec via provider.Create in
// order and returns the first success plus the spec that worked. If ALL fail it
// returns an AGGREGATED error listing each candidate's type/location and its
// (now-visible, thanks to stderr surfacing) underlying error — so a real failure
// (e.g. an ssh-key not found) is obvious rather than hidden behind a vague "all
// unavailable". It is a FREE function, not an interface method (the CloudProvider
// contract stays Create/IP/Delete/List).
func CreateWithFallback(ctx context.Context, provider CloudProvider, base ServerSpec) (Server, ServerSpec, error) {
	candidates := HetznerCandidates(base)
	var sb strings.Builder
	for _, spec := range candidates {
		srv, err := provider.Create(ctx, spec)
		if err == nil {
			return srv, spec, nil
		}
		fmt.Fprintf(&sb, "\n  - %s/%s: %s", spec.ServerType, spec.Region, strings.TrimSpace(err.Error()))
	}
	return Server{}, ServerSpec{}, fmt.Errorf("create %q failed on all %d candidate type/locations:%s", base.Name, len(candidates), sb.String())
}

// hcloudIPArgv builds the argv that reads back a server's public IPv4 —
// `hcloud server ip <name>` — matching the IP read-back step in provision.go.
func hcloudIPArgv(name string) []string {
	return []string{"hcloud", "server", "ip", name}
}

// HcloudProvider is the real CloudProvider. It shells out to the `hcloud` CLI
// with the same argv and the same os/exec mechanism setup/provision.go uses,
// and reads auth from HCLOUD_TOKEN / an active `hcloud context` — no extra
// surface. The zero value is usable.
type HcloudProvider struct{}

// HasAuth reports whether an hcloud credential is present: HCLOUD_TOKEN set or
// an `hcloud context` active. It mirrors the auth gate in setup/provision.go
// (os.Getenv("HCLOUD_TOKEN") != "" || hcloudContextActive()) so the real
// provider's notion of "authenticated" is identical to today's.
func (HcloudProvider) HasAuth(ctx context.Context) bool {
	if os.Getenv("HCLOUD_TOKEN") != "" {
		return true
	}
	if _, err := exec.LookPath("hcloud"); err != nil {
		return false
	}
	out, err := runCapture(ctx, "hcloud", "context", "active")
	return err == nil && strings.TrimSpace(out) != ""
}

// Create resolves the account's ssh-key, runs `hcloud server create …`, then
// reads the new server's IP back via `hcloud server ip <name>`. The argv is built
// by the pure hcloudCreateArgv / hcloudIPArgv helpers, so a real run and the argv
// test exercise the same bytes. On a create failure it surfaces hcloud's captured
// stderr (e.g. "ssh key not found", "resource_unavailable") — never a bare
// "exit status 1". The ssh-key is resolved FIRST: on a resolution error it
// returns without creating, so a bad/empty key never reaches hcloud.
func (h HcloudProvider) Create(ctx context.Context, spec ServerSpec) (Server, error) {
	sshKey, err := resolveSSHKey(ctx)
	if err != nil {
		return Server{}, fmt.Errorf("hcloud server create %q: %w", spec.Name, err)
	}
	argv := hcloudCreateArgv(spec, sshKey)
	if out, err := runCapture(ctx, argv[0], argv[1:]...); err != nil {
		return Server{}, fmt.Errorf("hcloud server create %q: %w: %s", spec.Name, err, strings.TrimSpace(out))
	}
	ip, err := h.IP(ctx, spec.Name)
	if err != nil {
		// The server WAS created but we can't read its IP back, so the caller gets
		// no host and cleanupHost can never tear it down → a billed orphan. Delete
		// the just-created server here (best-effort) before returning, so a failed
		// IP read-back never leaks a paid box. The delete uses a FRESH context so a
		// cancelled/timed-out create ctx still gets to tear down. We surface the IP
		// error (the real fault); a delete error is appended so a leaked box is at
		// least visible in the message.
		dctx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
		defer cancel()
		if derr := h.Delete(dctx, spec.Name); derr != nil {
			return Server{}, fmt.Errorf("hcloud server create %q: ip read-back failed: %w; AND cleanup delete of the orphan failed: %v", spec.Name, err, derr)
		}
		return Server{}, fmt.Errorf("hcloud server create %q: ip read-back failed (created server deleted to avoid an orphan): %w", spec.Name, err)
	}
	return Server{Name: spec.Name, IP: ip}, nil
}

// IP returns the server's public IPv4 via `hcloud server ip <name>`, surfacing
// hcloud's captured output on failure.
func (HcloudProvider) IP(ctx context.Context, name string) (string, error) {
	argv := hcloudIPArgv(name)
	out, err := runCapture(ctx, argv[0], argv[1:]...)
	if err != nil {
		return "", fmt.Errorf("hcloud server ip %q: %w: %s", name, err, strings.TrimSpace(out))
	}
	return strings.TrimSpace(out), nil
}

// Delete tears the server down via `hcloud server delete <name>`, surfacing
// hcloud's captured output on failure.
func (HcloudProvider) Delete(ctx context.Context, name string) error {
	if out, err := runCapture(ctx, "hcloud", "server", "delete", name); err != nil {
		return fmt.Errorf("hcloud server delete %q: %w: %s", name, err, strings.TrimSpace(out))
	}
	return nil
}

// List returns the servers hcloud reports. It is intentionally thin — the
// machine-readable parse can grow when a caller needs it; today it surfaces the
// names hcloud prints so callers can confirm a host exists. No pagination
// (YAGNI): the fleet is tiny.
func (HcloudProvider) List(ctx context.Context) ([]Server, error) {
	out, err := runCapture(ctx, "hcloud", "server", "list", "-o", "columns=name,ipv4")
	if err != nil {
		return nil, fmt.Errorf("hcloud server list: %w: %s", err, strings.TrimSpace(out))
	}
	var servers []Server
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		// Skip the column header row hcloud prints first.
		if i == 0 && strings.EqualFold(fields[0], "NAME") {
			continue
		}
		s := Server{Name: fields[0]}
		if len(fields) > 1 {
			s.IP = fields[1]
		}
		servers = append(servers, s)
	}
	return servers, nil
}

// LabelServer adds (or overwrites) a single label on an EXISTING server via
// `hcloud server add-label --overwrite <name> <key>=<val>`. --overwrite makes it
// idempotent (re-labeling an already-orphaned box does not error). It is used
// best-effort in the teardown path to stamp barkpark-orphaned=true on a box whose
// Delete persistently failed, so SweepOrphans can recover it later. On failure it
// surfaces hcloud's captured output.
func (HcloudProvider) LabelServer(ctx context.Context, name, key, val string) error {
	if out, err := runCapture(ctx, "hcloud", "server", "add-label", "--overwrite", name, key+"="+val); err != nil {
		return fmt.Errorf("hcloud server add-label %q %s=%s: %w: %s", name, key, val, err, strings.TrimSpace(out))
	}
	return nil
}

// hcloudServerJSON is the subset of `hcloud server list -o json` SweepOrphans
// needs: the name, its public IPv4, and the box's labels (so the recorded
// barkpark-fqdn label rides back for the DNS cleanup). Only these fields are
// decoded; the rest of hcloud's rich JSON is ignored.
type hcloudServerJSON struct {
	Name      string            `json:"name"`
	Labels    map[string]string `json:"labels"`
	PublicNet struct {
		IPv4 struct {
			IP string `json:"ip"`
		} `json:"ipv4"`
	} `json:"public_net"`
}

// ListByLabel returns the servers carrying key=val, via
// `hcloud server list -l <key>=<val> -o json`. The label selector is applied
// server-side so only matching boxes come back, and the JSON view carries each
// box's full label set — so SweepOrphans gets the barkpark-fqdn label back to
// clean up the stranded DNS record. It is the safe input to SweepOrphans: a box
// labeled barkpark-orphaned=true was definitively meant to be gone.
func (HcloudProvider) ListByLabel(ctx context.Context, key, val string) ([]Server, error) {
	out, err := runCapture(ctx, "hcloud", "server", "list", "-l", key+"="+val, "-o", "json")
	if err != nil {
		return nil, fmt.Errorf("hcloud server list -l %s=%s: %w: %s", key, val, err, strings.TrimSpace(out))
	}
	var raw []hcloudServerJSON
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("hcloud server list -l %s=%s: decode: %w", key, val, err)
	}
	servers := make([]Server, 0, len(raw))
	for _, r := range raw {
		servers = append(servers, Server{Name: r.Name, IP: r.PublicNet.IPv4.IP, Labels: r.Labels})
	}
	return servers, nil
}

// runCapture runs argv and returns its combined stdout+stderr — the same capture
// mechanism setup/steps.go uses (exec.CommandContext, combined buffer). Kept
// package-local so the cloud seam carries no dependency on the setup package.
//
// It is a package VAR (not a plain func) for the same reason sshKeyLister is: a
// test can swap in a recorder to drive HcloudProvider.Create's create→ip→delete
// sequence WITHOUT shelling out to real `hcloud` (no spend, no live server).
// Production never reassigns it.
var runCapture = func(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// runCaptureWithEnv runs argv exactly like runCapture but with `extraEnv`
// (KEY=VALUE strings) appended to the inherited process environment — later
// entries win, so a duplicate key overrides. Used by CloudDNS to run
// `hcloud zone rrset` against a DIFFERENT Cloud token (the project that owns the
// DNS zone) than the compute token, without disturbing the worker's own env.
// Package VAR for the same test-swap reason as runCapture.
var runCaptureWithEnv = func(ctx context.Context, extraEnv []string, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), extraEnv...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// compile-time assertions that HcloudProvider satisfies the core interface and
// the optional label-aware capabilities the orphan-recovery path uses.
var (
	_ CloudProvider = HcloudProvider{}
	_ ServerLabeler = HcloudProvider{}
	_ LabelLister   = HcloudProvider{}
)
