package provisioner

import (
	"context"
	"fmt"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// DeprovisionSpec is one claimed deprovision job as the control plane hands it
// back — the EXACT JSON the Elixir deprovision claim endpoint returns on 200 (a
// 204 means no pending job). The control plane never stored the random-suffixed
// Hetzner server name, so it hands back the box's IP (the worker resolves the
// name by matching it against the barkpark-managed label list) plus the DNS A
// record's label + zone.
type DeprovisionSpec struct {
	JobID    string `json:"job_id"`
	IP       string `json:"ip"`
	DNSLabel string `json:"dns_label"`
	DNSZone  string `json:"dns_zone"`
}

// DeprovisionFunc tears down one box (server + DNS) for a claimed deprovision
// job. Injected like ProvisionFunc/SweepFunc so the worker stays transport-only
// and tests drive it against the cloud fakes. It is naturally IDEMPOTENT (delete-
// if-exists), so a re-run after a dropped succeed-report is a safe no-op — there
// is NO orphan edge to guard (unlike provision), because deprovision deletes
// rather than creates.
type DeprovisionFunc func(ctx context.Context, spec DeprovisionSpec) error

// DeprovisionWith deletes the box behind spec via the seams' provider+DNS. Thin
// bridge to cloud.WarmPool.DeprovisionByIP — finds the managed server whose IP
// matches spec.IP, deletes it, deletes the DNS A record. Idempotent.
func DeprovisionWith(ctx context.Context, seams Seams, spec DeprovisionSpec) error {
	if seams.Provider == nil {
		return fmt.Errorf("provisioner: a CloudProvider must be set to deprovision")
	}
	wp := &cloud.WarmPool{Provider: seams.Provider, DNS: seams.DNS}
	return wp.DeprovisionByIP(ctx, spec.IP, spec.DNSLabel, spec.DNSZone)
}

// DefaultDeprovision returns a DeprovisionFunc bound to seams — the value the
// Worker calls per deprovision job. Tests bind it to the fakes; main() binds it
// to the real Hetzner provider/DNS (the SAME seams as provision/sweep).
func DefaultDeprovision(seams Seams) DeprovisionFunc {
	return func(ctx context.Context, spec DeprovisionSpec) error {
		return DeprovisionWith(ctx, seams, spec)
	}
}
