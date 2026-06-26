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
// the name it was created under, and its public IPv4 (empty until known).
type Server struct {
	ID   string
	Name string
	IP   string
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

// DefaultSpec returns the region/type/image fallbacks for a provider so a bare
// `--provider hetzner` still renders a complete spec. It mirrors
// setup.defaultsFor verbatim for hetzner (nbg1 / cax11 / ubuntu-22.04); Name is
// left empty for the caller to fill. An unknown provider yields a zero spec.
func DefaultSpec(provider string) ServerSpec {
	switch provider {
	case ProviderHetzner:
		return ServerSpec{Region: "nbg1", ServerType: "cax11", Image: "ubuntu-22.04"}
	default:
		return ServerSpec{}
	}
}

// hcloudSSHKey resolves the ssh-key NAME passed to `hcloud server create`. It
// mirrors setup.provisionSSHKey byte-for-byte: BARKPARK_SSH_KEY when set, else
// the "barkpark" placeholder (real creation is gated on auth upstream, so a
// wrong key fails fast there, never in a dry-run).
func hcloudSSHKey() string {
	if k := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY")); k != "" {
		return k
	}
	return "barkpark"
}

// hcloudCreateArgv builds the exact argv `bp setup --target provision` execs to
// create a Hetzner server today. It is a PURE function (no exec, no env beyond
// the ssh-key resolution) so a test can assert the argv without invoking hcloud.
// The flag order and values are byte-for-byte equivalent to the real Argv in
// setup/provision.go: name, type, image, location, ssh-key.
func hcloudCreateArgv(spec ServerSpec) []string {
	return []string{
		"hcloud", "server", "create",
		"--name", spec.Name,
		"--type", spec.ServerType,
		"--image", spec.Image,
		"--location", spec.Region,
		"--ssh-key", hcloudSSHKey(),
	}
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

// Create runs `hcloud server create …`, then reads the new server's IP back via
// `hcloud server ip <name>`. The argv is built by the pure hcloudCreateArgv /
// hcloudIPArgv helpers, so a real run and the argv test exercise the same bytes.
func (h HcloudProvider) Create(ctx context.Context, spec ServerSpec) (Server, error) {
	argv := hcloudCreateArgv(spec)
	if _, err := runCapture(ctx, argv[0], argv[1:]...); err != nil {
		return Server{}, fmt.Errorf("hcloud server create %q: %w", spec.Name, err)
	}
	ip, err := h.IP(ctx, spec.Name)
	if err != nil {
		return Server{}, err
	}
	return Server{Name: spec.Name, IP: ip}, nil
}

// IP returns the server's public IPv4 via `hcloud server ip <name>`.
func (HcloudProvider) IP(ctx context.Context, name string) (string, error) {
	argv := hcloudIPArgv(name)
	out, err := runCapture(ctx, argv[0], argv[1:]...)
	if err != nil {
		return "", fmt.Errorf("hcloud server ip %q: %w", name, err)
	}
	return strings.TrimSpace(out), nil
}

// Delete tears the server down via `hcloud server delete <name>`.
func (HcloudProvider) Delete(ctx context.Context, name string) error {
	if _, err := runCapture(ctx, "hcloud", "server", "delete", name); err != nil {
		return fmt.Errorf("hcloud server delete %q: %w", name, err)
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
		return nil, fmt.Errorf("hcloud server list: %w", err)
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

// runCapture runs argv and returns its combined stdout+stderr — the same capture
// mechanism setup/steps.go uses (exec.CommandContext, combined buffer). Kept
// package-local so the cloud seam carries no dependency on the setup package.
func runCapture(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// compile-time assertion that HcloudProvider satisfies the interface.
var _ CloudProvider = HcloudProvider{}
