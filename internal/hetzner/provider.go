// APIProvider is the native cloud.CloudProvider: the same contract the argv
// HcloudProvider (internal/cli/cloud/provider.go) fulfills by exec'ing the
// `hcloud` CLI, fulfilled here by SDK calls against api.hetzner.cloud. Same
// method set (Create/IP/Delete/List + LabelServer + ListByLabel), same label
// keys (cloud.ManagedLabelKey stamped at create), same tolerances (delete of
// an absent box is a no-op), same ssh-key resolution order (BARKPARK_SSH_KEY,
// else the account's single key, else a clear error) — so the provisioner can
// swap providers without any behavior change.
package hetzner

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// cleanupTimeout bounds the fresh teardown context Create uses when the IP
// read-back fails after the box exists — mirroring the cloud package's own
// cleanupTimeout so a failed create never leaks a billed orphan.
const cleanupTimeout = 2 * time.Minute

// APIProvider implements cloud.CloudProvider (plus the optional ServerLabeler
// and LabelLister capabilities) over the hcloud SDK.
type APIProvider struct {
	client *Client
}

// NewAPIProvider wraps an authenticated Client as a cloud provider.
func NewAPIProvider(c *Client) *APIProvider {
	return &APIProvider{client: c}
}

// resolveSSHKey resolves the account SSH key servers are created with, with
// the SAME order as the argv provider's resolveSSHKey: BARKPARK_SSH_KEY when
// set (name or numeric id), else the account's keys when EXACTLY ONE exists,
// else a clear "set BARKPARK_SSH_KEY" error (0 or N>1 are both ambiguous).
// Unlike the argv path — which passes the ssh-key NAME to `hcloud` — the API
// wants the key's numeric id, so resolution returns the full *hcloud.SSHKey.
func (p *APIProvider) resolveSSHKey(ctx context.Context) (*hcloud.SSHKey, error) {
	if want := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY")); want != "" {
		key, _, err := p.client.hc.SSHKey.Get(ctx, want)
		if err != nil {
			return nil, fmt.Errorf("look up ssh key %q: %w", want, err)
		}
		if key == nil {
			return nil, fmt.Errorf("ssh key %q (from BARKPARK_SSH_KEY) not found", want)
		}
		return key, nil
	}
	keys, err := p.client.hc.SSHKey.All(ctx)
	if err != nil {
		return nil, fmt.Errorf("set BARKPARK_SSH_KEY: could not list ssh keys: %w", err)
	}
	if len(keys) == 1 {
		return keys[0], nil
	}
	return nil, fmt.Errorf("set BARKPARK_SSH_KEY: found %d ssh keys (need exactly one to auto-select)", len(keys))
}

// imageRef maps the spec's image string onto hcloud.Image: a numeric value is
// a snapshot ID (BARKPARK_SERVER_IMAGE is documented as the baked warm-pool
// snapshot id), anything else an image name like ubuntu-22.04.
func imageRef(image string) *hcloud.Image {
	if id, err := strconv.ParseInt(image, 10, 64); err == nil {
		return &hcloud.Image{ID: id}
	}
	return &hcloud.Image{Name: image}
}

// Create provisions a server per spec: resolve the ssh key FIRST (a resolution
// error returns before anything is created), POST /servers with the
// barkpark-managed=true label the whole fleet carries, wait the returned
// action(s) to completion (create is async — the argv `hcloud server create`
// does the same wait internally), then return the public IPv4. If the box was
// created but the wait/read-back fails, it is deleted best-effort on a FRESH
// bounded context so a failed create never leaks a billed orphan — the same
// guarantee HcloudProvider.Create gives.
func (p *APIProvider) Create(ctx context.Context, spec cloud.ServerSpec) (cloud.Server, error) {
	sshKey, err := p.resolveSSHKey(ctx)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("hetzner create %q: %w", spec.Name, err)
	}

	opts := hcloud.ServerCreateOpts{
		Name:       spec.Name,
		ServerType: &hcloud.ServerType{Name: spec.ServerType},
		Image:      imageRef(spec.Image),
		Location:   &hcloud.Location{Name: spec.Region},
		SSHKeys:    []*hcloud.SSHKey{sshKey},
		Labels:     map[string]string{cloud.ManagedLabelKey: "true"},
	}
	result, _, err := p.client.hc.Server.Create(ctx, opts)
	if err != nil {
		return cloud.Server{}, fmt.Errorf("hetzner create %q: %w", spec.Name, err)
	}

	actions := append([]*hcloud.Action{result.Action}, result.NextActions...)
	if err := p.client.hc.Action.WaitFor(ctx, actions...); err != nil {
		return cloud.Server{}, p.cleanupFailedCreate(spec.Name, fmt.Errorf("hetzner create %q: waiting for create action: %w", spec.Name, err))
	}

	// The create response usually carries the assigned IPv4 already; fall back
	// to a read-back when it doesn't (e.g. an IP allocated only once running).
	if result.Server != nil && result.Server.PublicNet.IPv4.IP != nil {
		return cloud.Server{
			ID:   strconv.FormatInt(result.Server.ID, 10),
			Name: spec.Name,
			IP:   result.Server.PublicNet.IPv4.IP.String(),
		}, nil
	}
	ip, err := p.IP(ctx, spec.Name)
	if err != nil {
		return cloud.Server{}, p.cleanupFailedCreate(spec.Name, fmt.Errorf("hetzner create %q: ip read-back failed: %w", spec.Name, err))
	}
	return cloud.Server{Name: spec.Name, IP: ip}, nil
}

// cleanupFailedCreate best-effort deletes a box whose create went bad after it
// started existing, on a fresh bounded context (the create ctx may already be
// cancelled). The original cause is always surfaced; a delete failure is
// appended so a leaked box is at least visible in the message.
func (p *APIProvider) cleanupFailedCreate(name string, cause error) error {
	dctx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
	defer cancel()
	if derr := p.Delete(dctx, name); derr != nil {
		return fmt.Errorf("%w; AND cleanup delete of the orphan failed: %v", cause, derr)
	}
	return cause
}

// getByName looks a server up by name. The SDK returns (nil, nil) for an
// unknown name — callers decide whether absence is an error (IP) or fine
// (Delete).
func (p *APIProvider) getByName(ctx context.Context, name string) (*hcloud.Server, error) {
	srv, _, err := p.client.hc.Server.GetByName(ctx, name)
	if err != nil {
		return nil, err
	}
	return srv, nil
}

// IP returns the server's public IPv4, mirroring `hcloud server ip <name>`:
// an unknown server (or one without a public IPv4) is an error.
func (p *APIProvider) IP(ctx context.Context, name string) (string, error) {
	srv, err := p.getByName(ctx, name)
	if err != nil {
		return "", fmt.Errorf("hetzner server ip %q: %w", name, err)
	}
	if srv == nil {
		return "", fmt.Errorf("hetzner server ip %q: server not found", name)
	}
	if srv.PublicNet.IPv4.IP == nil {
		return "", fmt.Errorf("hetzner server ip %q: server has no public IPv4", name)
	}
	return srv.PublicNet.IPv4.IP.String(), nil
}

// Delete tears the server down by name and is IDEMPOTENT: an already-absent
// box (unknown name, or a not_found on the delete itself — e.g. a concurrent
// teardown won the race) is a no-op, because the desired end state (no such
// server) already holds. That tolerance is what the teardown/orphan-sweep
// paths rely on.
func (p *APIProvider) Delete(ctx context.Context, name string) error {
	srv, err := p.getByName(ctx, name)
	if err != nil {
		return fmt.Errorf("hetzner server delete %q: %w", name, err)
	}
	if srv == nil {
		return nil // idempotent: already gone
	}
	result, _, err := p.client.hc.Server.DeleteWithResult(ctx, srv)
	if err != nil {
		if hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
			return nil // idempotent: raced away between lookup and delete
		}
		return fmt.Errorf("hetzner server delete %q: %w", name, err)
	}
	if err := p.client.hc.Action.WaitFor(ctx, result.Action); err != nil {
		return fmt.Errorf("hetzner server delete %q: waiting for delete action: %w", name, err)
	}
	return nil
}

// List returns every server in the project as name+IPv4. Labels are left nil,
// matching the argv provider's plain List (only the label-aware ListByLabel
// populates them — the documented contract on cloud.Server).
func (p *APIProvider) List(ctx context.Context) ([]cloud.Server, error) {
	srvs, err := p.client.hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{})
	if err != nil {
		return nil, fmt.Errorf("hetzner server list: %w", err)
	}
	return toCloudServers(srvs, false), nil
}

// ListByLabel returns the servers carrying key=val via a server-side
// LabelSelector — the SDK analogue of `hcloud server list -l k=v -o json` —
// with each box's full label set riding back (SweepOrphans reads the
// barkpark-fqdn label off it to clean up the stranded DNS record).
func (p *APIProvider) ListByLabel(ctx context.Context, key, val string) ([]cloud.Server, error) {
	opts := hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: key + "=" + val},
	}
	srvs, err := p.client.hc.Server.AllWithOpts(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("hetzner server list -l %s=%s: %w", key, val, err)
	}
	return toCloudServers(srvs, true), nil
}

// LabelServer adds-or-overwrites a single label on an existing server — the
// SDK analogue of `hcloud server add-label --overwrite`. The server's OTHER
// labels are preserved (the API's update replaces the whole label map, so the
// existing set is copied and only key is written). Idempotent: re-labeling an
// already-labeled box succeeds.
func (p *APIProvider) LabelServer(ctx context.Context, name, key, val string) error {
	srv, err := p.getByName(ctx, name)
	if err != nil {
		return fmt.Errorf("hetzner server add-label %q %s=%s: %w", name, key, val, err)
	}
	if srv == nil {
		return fmt.Errorf("hetzner server add-label %q %s=%s: server not found", name, key, val)
	}
	labels := make(map[string]string, len(srv.Labels)+1)
	for k, v := range srv.Labels {
		labels[k] = v
	}
	labels[key] = val
	if _, _, err := p.client.hc.Server.Update(ctx, srv, hcloud.ServerUpdateOpts{Labels: labels}); err != nil {
		return fmt.Errorf("hetzner server add-label %q %s=%s: %w", name, key, val, err)
	}
	return nil
}

// toCloudServers maps SDK servers onto the cloud seam's Server. withLabels
// mirrors the argv contract: plain List leaves Labels nil, ListByLabel carries
// them.
func toCloudServers(srvs []*hcloud.Server, withLabels bool) []cloud.Server {
	out := make([]cloud.Server, 0, len(srvs))
	for _, s := range srvs {
		cs := cloud.Server{
			ID:   strconv.FormatInt(s.ID, 10),
			Name: s.Name,
		}
		if s.PublicNet.IPv4.IP != nil {
			cs.IP = s.PublicNet.IPv4.IP.String()
		}
		if withLabels {
			cs.Labels = s.Labels
		}
		out = append(out, cs)
	}
	return out
}

// compile-time assertions: APIProvider is a drop-in for HcloudProvider — the
// core contract plus both optional capabilities.
var (
	_ cloud.CloudProvider = (*APIProvider)(nil)
	_ cloud.ServerLabeler = (*APIProvider)(nil)
	_ cloud.LabelLister   = (*APIProvider)(nil)
)
