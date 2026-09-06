package cli

// hetzner_instance_cmd.go is the fleet-lifecycle admin surface — the verbs that
// treat a whole Barkpark instance (server + DNS record + control-plane registry
// row) as ONE unit, so removing or moving an instance can never strand half of
// it (a billed orphan box, a dangling A record, a stale dashboard row):
//
//	bp cloud hetzner instance archive      <fqdn|server>   snapshot + resurrection labels
//	bp cloud hetzner instance archives     [<fqdn>]        list archives
//	bp cloud hetzner instance decommission <fqdn|server>   archive → teardown → verify NO residue
//	bp cloud hetzner instance resurrect    <fqdn>          newest archive → server → DNS → health
//	bp cloud hetzner instance adopt        <fqdn> --team   standalone → SaaS tenant (clone-swap)
//	bp cloud hetzner instance eject        <fqdn|slug>     SaaS tenant → standalone (clone-swap)
//	bp cloud hetzner instance audit                        servers ↔ DNS ↔ registry cross-check
//
// An ARCHIVE is a Hetzner snapshot image stamped with resurrection metadata as
// labels (fqdn, server type, location) — fully self-contained: the box's
// Postgres, media, secrets and Caddy certs are all inside the image, so
// `resurrect` needs nothing but the image. (An S3 sink for portable, off-
// Hetzner archives slots in once Object Storage credentials exist — the
// storage/backup commands already carry the client.)
//
// Three credentials, three seams:
//   - compute: --token > HCLOUD_TOKEN > hcloud context (hetznerClient — the
//     project the fleet's servers live in)
//   - DNS: --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > the compute token (the
//     zone may live in a DIFFERENT Hetzner project — the provisioner's seam)
//   - registry: --control-url > BARKPARK_CONTROL_URL (default
//     https://barkpark.cloud) + --worker-token > WORKER_TOKEN. Absent token →
//     registry steps are SKIPPED with a visible note (direct mode), never
//     silently.
//
// decommission prefers the control plane's own deprovision queue (the worker
// tears the box + DNS down and deletes the row — the product path, exercised
// end-to-end) and falls back to direct teardown guarded by the barkpark-fqdn
// label, mirroring cloud.WarmPool.DeprovisionByIP: never delete by IP alone,
// Hetzner recycles IPs. Every teardown ends with a residue VERIFICATION
// (server gone, DNS gone, row gone) and a non-zero exit if anything survived.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// Archive-image label keys. barkpark-fqdn reuses the server-side key so one
// grep finds both; the rest pin what resurrect needs to rebuild the box.
const (
	instArchiveLabelKey = "barkpark-archive" // "true" on every bp-made archive
	instArchiveTypeKey  = "barkpark-server-type"
	instArchiveLocKey   = "barkpark-location"
)

// instDefaultZone is the fleet's DNS zone — overridable per call with --zone.
const instDefaultZone = "barkpark.cloud"

// instDefaultControlURL is where the registry lives when --control-url /
// BARKPARK_CONTROL_URL don't say otherwise.
const instDefaultControlURL = "https://barkpark.cloud"

// Poll seams — vars so tests run instantly. instPollMax bounds both the
// worker-teardown wait and the resurrect health gate (instPoll × instPollMax).
var (
	instPoll    = 5 * time.Second
	instPollMax = 90
)

// instHTTP performs control-plane calls and health probes. A var so tests can
// shrink timeouts; the generous default rides out a cold Phoenix boot.
var instHTTP = &http.Client{Timeout: 20 * time.Second}

// instSSH runs one command on a box as root (the provisioner's key
// conventions: BARKPARK_SSH_KEY_FILE > ~/.ssh/barkpark_indx). Used only for
// the optional clean-stop before a snapshot; a failure degrades to an online
// (crash-consistent) snapshot, never blocks. A var so tests stub it.
var instSSH = func(host, command string) error {
	key := strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY_FILE"))
	if key == "" {
		if home, err := os.UserHomeDir(); err == nil {
			key = filepath.Join(home, ".ssh", "barkpark_indx")
		}
	}
	cmd := exec.Command("ssh",
		"-i", key,
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		"root@"+host, command)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ssh root@%s: %w: %s", host, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// instStopCommand quiesces the data writers before a snapshot so the image is
// application-consistent, not just crash-consistent. Caddy stays up (it holds
// no state); the box is either about to die (decommission) or has a clone
// taking over (adopt/eject), so the brief API outage is honest.
const instStopCommand = "systemctl stop barkpark 2>/dev/null; systemctl stop postgresql 2>/dev/null; sync"

func runHetznerInstance(out *writer, g globals, args []string) int {
	if g.help {
		printHetznerInstanceHelp(out)
		return exitOK
	}
	if len(args) == 0 {
		return useError(out, "usage", "missing instance command (run `bp cloud hetzner instance -h` for usage)", exitUsage)
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "archive":
		return runInstanceArchive(out, g, rest)
	case "archives", "list-archives":
		return runInstanceArchives(out, g, rest)
	case "decommission", "decom", "retire":
		return runInstanceDecommission(out, g, rest)
	case "resurrect", "restore":
		return runInstanceResurrect(out, g, rest)
	case "adopt":
		return runInstanceAdopt(out, g, rest)
	case "eject":
		return runInstanceEject(out, g, rest)
	case "export":
		return runInstanceExport(out, g, rest)
	case "import":
		return runInstanceImport(out, g, rest)
	case "audit":
		return runInstanceAudit(out, g, rest)
	case "help":
		printHetznerInstanceHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown instance command %q (run `bp cloud hetzner instance -h` for usage)", verb), exitUsage)
	}
}

// ---------------------------------------------------------------------------
// credentials: the DNS-project client and the control-plane (registry) client
// ---------------------------------------------------------------------------

// instDNSClient returns the client for zone/rrset calls: --dns-token >
// BARKPARK_DNS_HCLOUD_TOKEN > the compute credentials. The zone may live in a
// different Hetzner project than the servers (the provisioner's two-token
// seam), so this is deliberately a SECOND client.
func instDNSClient(out *writer, g globals, a *hzArgs) (*hcloud.Client, bool) {
	tok := strings.TrimSpace(a.val("dns-token"))
	if tok == "" {
		tok = strings.TrimSpace(os.Getenv("BARKPARK_DNS_HCLOUD_TOKEN"))
	}
	if tok == "" {
		c, ok := hetznerClient(out, g)
		if !ok {
			return nil, false
		}
		return c.HCloud(), true
	}
	return newHetznerClient(tok).HCloud(), true
}

func instDNSUsesComputeToken(a *hzArgs) bool {
	return strings.TrimSpace(a.val("dns-token")) == "" &&
		strings.TrimSpace(os.Getenv("BARKPARK_DNS_HCLOUD_TOKEN")) == ""
}

// cpFleet is the control-plane registry client, authenticated with the shared
// WORKER_TOKEN (the same credential the provisioner drains its queues with).
// nil ⇔ no token available: registry steps are skipped, visibly.
type cpFleet struct {
	base  string
	token string
}

// instCP builds the registry client from --control-url/--worker-token with
// their env fallbacks, or returns nil when no worker token is available.
func instCP(a *hzArgs) *cpFleet {
	tok := strings.TrimSpace(a.val("worker-token"))
	if tok == "" {
		tok = strings.TrimSpace(os.Getenv("WORKER_TOKEN"))
	}
	if tok == "" {
		return nil
	}
	base := strings.TrimSpace(a.val("control-url"))
	if base == "" {
		base = strings.TrimSpace(os.Getenv("BARKPARK_CONTROL_URL"))
	}
	if base == "" {
		base = instDefaultControlURL
	}
	return &cpFleet{base: strings.TrimRight(base, "/"), token: tok}
}

// cpBarkpark is one registry row as GET /v1/internal/barkparks returns it.
type cpBarkpark struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Slug              string `json:"slug"`
	Host              string `json:"host"`
	URL               string `json:"url"`
	DNSLabel          string `json:"dns_label"`
	Mode              string `json:"mode"`
	HealthStatus      string `json:"health_status"`
	Suspended         bool   `json:"suspended"`
	TeamID            string `json:"team_id"`
	ProvisionStatus   string `json:"provision_status"`
	DeprovisionStatus string `json:"deprovision_status"`
}

func (cp *cpFleet) do(method, path string, body any) (*http.Response, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = strings.NewReader(string(b))
	}
	req, err := http.NewRequest(method, cp.base+path, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+cp.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return instHTTP.Do(req)
}

// List fetches every registry row across all teams.
func (cp *cpFleet) List() ([]cpBarkpark, error) {
	resp, err := cp.do(http.MethodGet, "/v1/internal/barkparks", nil)
	if err != nil {
		return nil, fmt.Errorf("control plane list: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("control plane list: HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Barkparks []cpBarkpark `json:"barkparks"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("control plane list: decode: %w", err)
	}
	return payload.Barkparks, nil
}

// Deprovision removes one row. detach=false rides the product path (a LIVE row
// enqueues a worker deprovision job — the worker tears the box + DNS down,
// then the row is deleted). detach=true deletes the ROW ONLY — for a row whose
// `host` is stale (recycled IP now owned by another instance) or whose box the
// caller manages itself; the caller asserts no live box of this row is
// stranded. Returns the reported status ("deprovisioning" | "removed").
func (cp *cpFleet) Deprovision(id string, detach bool) (string, error) {
	var body any
	if detach {
		body = map[string]string{"mode": "detach"}
	}
	resp, err := cp.do(http.MethodPost, "/v1/internal/barkparks/"+id+"/deprovision", body)
	if err != nil {
		return "", fmt.Errorf("control plane deprovision: %w", err)
	}
	defer resp.Body.Close()
	var payload struct {
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&payload)
	switch resp.StatusCode {
	case http.StatusOK, http.StatusAccepted:
		return payload.Status, nil
	default:
		what := payload.Error
		if what == "" {
			what = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		return "", fmt.Errorf("control plane deprovision: %s", what)
	}
}

// Adopt registers an already-running box as a managed row (the standalone →
// tenant path). admin_token is optional — without it the dashboard can list
// the instance but not drive its admin surface.
func (cp *cpFleet) Adopt(attrs map[string]string) (*cpBarkpark, error) {
	resp, err := cp.do(http.MethodPost, "/v1/internal/barkparks", attrs)
	if err != nil {
		return nil, fmt.Errorf("control plane adopt: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("control plane adopt: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var payload struct {
		Barkpark cpBarkpark `json:"barkpark"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("control plane adopt: decode: %w", err)
	}
	return &payload.Barkpark, nil
}

// findRow matches a registry row to a fqdn (by dns_label) or an IP (by host).
func cpFindRow(rows []cpBarkpark, label, zone, ip string) *cpBarkpark {
	for i := range rows {
		if rows[i].DNSLabel != "" && rows[i].DNSLabel == label {
			return &rows[i]
		}
	}
	if ip != "" {
		for i := range rows {
			if rows[i].Host == ip {
				return &rows[i]
			}
		}
	}
	return nil
}

// cpRowByID finds a registry row by ITS ID in a freshly-read list. Adopt's
// post-condition addresses the row the control plane said it created, so the
// match is on that id and nothing else: cpFindRow's dns_label/host heuristics
// would happily hand back a pre-existing row for the same label under another
// team and call the registration confirmed.
func cpRowByID(rows []cpBarkpark, id string) *cpBarkpark {
	if id == "" {
		return nil
	}
	for i := range rows {
		if rows[i].ID == id {
			return &rows[i]
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// shared plumbing
// ---------------------------------------------------------------------------

// instTarget resolves `<fqdn|label|server-name>` against the managed fleet.
// The server may legitimately be ABSENT (cleaning residue of an already-dead
// box) — then srv is nil and the fqdn is derived from the argument. A server
// found by name must carry the barkpark-fqdn label (or --fqdn must say).
func instTarget(ctx context.Context, hc *hcloud.Client, target, zone, fqdnFlag string) (srv *hcloud.Server, fqdn string, err error) {
	// Exact server name/id first.
	s, _, gerr := hc.Server.Get(ctx, target)
	if gerr != nil {
		return nil, "", gerr
	}
	if s != nil {
		fqdn = s.Labels[cloud.FQDNLabelKey]
		if fqdnFlag != "" {
			fqdn = fqdnFlag
		}
		if fqdn == "" {
			return nil, "", fmt.Errorf("server %q carries no %s label — pass --fqdn <label>.<zone> to name its DNS identity", s.Name, cloud.FQDNLabelKey)
		}
		return s, fqdn, nil
	}
	// Not a server name: treat as fqdn (or bare label in --zone).
	fqdn = strings.Trim(strings.TrimSpace(target), ".")
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + zone
	}
	servers, lerr := hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: cloud.ManagedLabelKey + "=true"},
	})
	if lerr != nil {
		return nil, "", lerr
	}
	for _, cand := range servers {
		if cand.Labels[cloud.FQDNLabelKey] == fqdn {
			return cand, fqdn, nil
		}
	}
	return nil, fqdn, nil // residue mode: no live box for this fqdn
}

// instLabelOf splits a fqdn into its first label and remaining zone.
func instLabelOf(fqdn string) (label, zone string) {
	parts := strings.SplitN(strings.Trim(fqdn, "."), ".", 2)
	if len(parts) < 2 {
		return parts[0], ""
	}
	return parts[0], parts[1]
}

// instArchiveObs is what an archive OBSERVED, as opposed to what the create
// action echoed back. The receipt is built from this and nothing else.
//
// Two facts in here are the difference between an honest archive receipt and a
// confident one:
//
//   - quiesced. A --stop archive whose SSH quiesce failed degrades to an
//     online, crash-consistent snapshot. That degradation was reported only
//     through out.info, and writer.info writes to stderr ONLY WHEN VERBOSE —
//     so `archive --stop -o json` emitted a BYTE-IDENTICAL receipt for a
//     cleanly-stopped Postgres and a live one. `quiesced` is therefore NOT
//     optional: every archive receipt states whether writers were stopped.
//   - image / confirm. The create action's response echoes an image id. The
//     action completing says the SNAPSHOT JOB finished, not that a usable
//     image exists, so the id is re-read (GET /images/<id>) and the receipt
//     carries the OBSERVED status. A read that cannot confirm is confirmation
//     unavailable, never a failed verb — the same escape the server verbs take.
type instArchiveObs struct {
	image      *hcloud.Image // the image the receipt names (FRESH when confirmed)
	status     string        // observed image status; "" when unconfirmed
	confirm    string        // "" = confirmed; else why confirmation is unavailable
	quiesced   bool          // writers were stopped before the snapshot
	asked      bool          // --stop asked for the quiesce
	quiesceErr string        // why the quiesce failed, when it was asked for and failed
}

// receipt renders the observed half of an archive receipt. Callers merge it
// into their own payload (fqdn, ipv4, …).
func (o *instArchiveObs) receipt() map[string]any {
	extra := map[string]any{
		"image_id": o.image.ID,
		"quiesced": o.quiesced,
	}
	if o.quiesceErr != "" {
		extra["quiesce_error"] = o.quiesceErr
	}
	if o.confirm != "" {
		extra["confirmation"] = "unavailable"
		extra["confirmation_error"] = o.confirm
		return extra
	}
	extra["image_status"] = o.status
	return extra
}

// instArchive snapshots srv with the resurrection labels, then RE-READS the
// image it created. stop=true quiesces the data writers first (best-effort — an
// unreachable box degrades to an online, crash-consistent snapshot, which the
// receipt reports as quiesced:false, never a hard stop).
func instArchive(ctx context.Context, out *writer, hc *hcloud.Client, srv *hcloud.Server, fqdn string, stop bool) (*instArchiveObs, error) {
	obs := &instArchiveObs{asked: stop}
	if stop && hzIPv4(srv) != "" {
		out.info("quiescing %s before the snapshot…", srv.Name)
		if err := instSSH(hzIPv4(srv), instStopCommand); err != nil {
			out.info("clean stop failed (%v) — taking an online snapshot instead", err)
			obs.quiesceErr = err.Error()
		} else {
			obs.quiesced = true
		}
	} else if stop {
		obs.quiesceErr = "the box reports no IPv4 address, so the writers could not be reached"
	}
	labels := map[string]string{
		instArchiveLabelKey: "true",
		cloud.FQDNLabelKey:  fqdn,
		instArchiveLocKey:   hzServerLocation(srv),
	}
	if srv.ServerType != nil {
		labels[instArchiveTypeKey] = srv.ServerType.Name
	}
	result, _, err := hc.Server.CreateImage(ctx, srv, &hcloud.ServerCreateImageOpts{
		Type:        hcloud.ImageTypeSnapshot,
		Description: hcloud.Ptr("bp archive " + fqdn + " (" + srv.Name + ")"),
		Labels:      labels,
	})
	if err != nil {
		return nil, fmt.Errorf("create archive of %s: %w", srv.Name, err)
	}
	out.info("archive of %s accepted (image %d) — waiting for the snapshot…", srv.Name, result.Image.ID)
	if err := hzWait(ctx, hc, result.Action); err != nil {
		return nil, fmt.Errorf("archive of %s: snapshot action failed: %w", srv.Name, err)
	}
	obs.image = result.Image

	// The post-condition, and the reason this verb is exempt from the SERVER
	// post-condition table rather than keyed in it: an archive changes no field
	// on hcloud.Server. What it must produce is an IMAGE, so the honest
	// confirmation is GET /images/<id> — the same ground create-image declared
	// and the follow-up row pds-w26-create-image-image-postcondition owns.
	// `creating` is not settled and not a failure: it is polled, then reported
	// as unconfirmed. Any other non-available status IS a failure — resurrect
	// and clone-swap both boot from this image, so shipping a broken one is
	// worse than failing here.
	fresh, _, gerr := hc.Image.GetByID(ctx, result.Image.ID)
	for i := 0; i < instPollMax && gerr == nil && fresh != nil && fresh.Status == hcloud.ImageStatusCreating; i++ {
		time.Sleep(instPoll)
		fresh, _, gerr = hc.Image.GetByID(ctx, result.Image.ID)
	}
	switch {
	case gerr != nil:
		obs.confirm = fmt.Sprintf("the snapshot image %d could not be re-read: %v", result.Image.ID, gerr)
	case fresh == nil:
		obs.confirm = fmt.Sprintf("the snapshot image %d is not readable, so the archive could not be confirmed", result.Image.ID)
	case fresh.Status == hcloud.ImageStatusCreating:
		obs.image = fresh
		obs.confirm = fmt.Sprintf("the snapshot image %d still reports status %q after %s, so the archive could not be confirmed",
			fresh.ID, fresh.Status, time.Duration(instPollMax)*instPoll)
	case fresh.Status != hcloud.ImageStatusAvailable:
		return nil, fmt.Errorf("archive of %s: the snapshot action completed but image %d reports status %q, not %q — "+
			"nothing can be restored from it", srv.Name, fresh.ID, fresh.Status, hcloud.ImageStatusAvailable)
	default:
		obs.image = fresh
		obs.status = string(fresh.Status)
	}
	return obs, nil
}

// instArchivesFor lists archive images, newest first, optionally fqdn-scoped.
func instArchivesFor(ctx context.Context, hc *hcloud.Client, fqdn string) ([]*hcloud.Image, error) {
	sel := instArchiveLabelKey + "=true"
	if fqdn != "" {
		sel += "," + cloud.FQDNLabelKey + "=" + fqdn
	}
	images, err := hc.Image.AllWithOpts(ctx, hcloud.ImageListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: sel},
		Type:     []hcloud.ImageType{hcloud.ImageTypeSnapshot},
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(images, func(i, j int) bool { return images[i].Created.After(images[j].Created) })
	return images, nil
}

// instUpsertA writes the A record label.zone → ip (create-or-replace).
func instUpsertA(ctx context.Context, dns *hcloud.Client, zone, label, ip string) error {
	rrset := &hcloud.ZoneRRSet{Zone: hzZoneRef(zone), Name: hzRRSetName(label), Type: hcloud.ZoneRRSetTypeA}
	records := []hcloud.ZoneRRSetRecord{{Value: ip}}
	action, _, err := dns.Zone.SetRRSetRecords(ctx, rrset, hcloud.ZoneRRSetSetRecordsOpts{Records: records})
	if err != nil {
		if hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
			result, _, cerr := dns.Zone.CreateRRSet(ctx, hzZoneRef(zone), hcloud.ZoneRRSetCreateOpts{
				Name: hzRRSetName(label), Type: hcloud.ZoneRRSetTypeA, Records: records,
			})
			if cerr != nil {
				return fmt.Errorf("dns create %s.%s: %w", label, zone, cerr)
			}
			return hzWait(ctx, dns, result.Action)
		}
		return fmt.Errorf("dns upsert %s.%s: %w", label, zone, err)
	}
	return hzWait(ctx, dns, action)
}

// instDeleteA removes the A rrset label.zone. Absent → idempotent no-op.
func instDeleteA(ctx context.Context, dns *hcloud.Client, zone, label string) error {
	rrset := &hcloud.ZoneRRSet{Zone: hzZoneRef(zone), Name: hzRRSetName(label), Type: hcloud.ZoneRRSetTypeA}
	result, _, err := dns.Zone.DeleteRRSet(ctx, rrset)
	if err != nil {
		if hcloud.IsError(err, hcloud.ErrorCodeNotFound) {
			return nil
		}
		return fmt.Errorf("dns delete %s.%s: %w", label, zone, err)
	}
	return hzWait(ctx, dns, result.Action)
}

// ── by-VALUE DNS (task-688ebffc4b0aa50a, PDF-D101) ───────────────────────────
//
// A teardown that deletes and verifies the fqdn's FIRST LABEL ONLY is blind by
// construction. The platform name is not the only A rrset a box owns: go-live
// publishes the `<slug>-<teamid>` sibling at the same address, and attach-domain
// upserts the customer's custom host there too. Deleting `<label>` releases the
// box while those keep resolving to an address Hetzner will hand to a stranger
// (subdomain takeover) — and, worse, a by-NAME verify then reads clean and the
// receipt exits zero. `bp cloud support remove` was fixed out of exactly this
// trap (cloud_support_cmd.go stepDNS + census leg 5, riding
// cloud.SweepARecordsByValue); these two helpers are the same law for the
// instance teardown, which speaks to the zone through *hcloud.Client directly.
//
// THE WIDENED BLAST RADIUS IS DELIBERATE and fenced the same way
// cloud.WarmPool.DeprovisionByIP fences it: a by-value sweep takes EVERY A rrset
// at the address, which is the point (an unknown extra name at a released
// address IS the orphan) — so callers sweep ONLY at an address they hold
// exclusively, and degrade to the by-name delete otherwise. Never wider than the
// box we actually own.

// instARecordNamesByValue returns the sorted names of every A rrset in zone
// holding a record whose value equals ip. Empty ip → no names and no call: a
// check that cannot see the address must never read as clean by accident.
func instARecordNamesByValue(ctx context.Context, dns *hcloud.Client, zone, ip string) ([]string, error) {
	if strings.TrimSpace(ip) == "" {
		return nil, nil
	}
	rrsets, err := dns.Zone.AllRRSets(ctx, hzZoneRef(zone))
	if err != nil {
		return nil, err
	}
	var names []string
	for _, rr := range rrsets {
		if rr.Type != hcloud.ZoneRRSetTypeA {
			continue
		}
		for _, rec := range rr.Records {
			if strings.TrimSpace(rec.Value) == ip {
				names = append(names, rr.Name)
				break
			}
		}
	}
	sort.Strings(names)
	return names, nil
}

// instSweepAByValue deletes every A rrset in zone that resolves to ip, returning
// the names it actually removed. An individual delete failure does not stop the
// sweep — the siblings still go — and the failures aggregate into the error
// alongside whatever WAS deleted (cloud.SweepARecordsByValue's contract).
func instSweepAByValue(ctx context.Context, dns *hcloud.Client, zone, ip string) ([]string, error) {
	names, err := instARecordNamesByValue(ctx, dns, zone, ip)
	if err != nil {
		return nil, err
	}
	var deleted, errs []string
	for _, name := range names {
		if derr := instDeleteA(ctx, dns, zone, hzLabelOfRRSetName(name)); derr != nil {
			errs = append(errs, derr.Error())
			continue
		}
		deleted = append(deleted, name)
	}
	if len(errs) > 0 {
		return deleted, fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return deleted, nil
}

// hzLabelOfRRSetName is hzRRSetName's inverse: the apex rrset is named "@" in
// the API and the empty label locally, so a sweep that read "@" back must hand
// the empty label to the delete rather than a literal at-sign.
func hzLabelOfRRSetName(name string) string {
	if name == "@" {
		return ""
	}
	return name
}

// instTeardownDNS is the DNS half of an instance teardown: sweep BY VALUE when
// the box's address is known AND exclusively ours, otherwise the historical
// by-name delete of the platform label. `exclusive` is the caller's answer to
// "do we hold this address alone?" — false (another managed box sits on it under
// a different identity) degrades to by-name, because a sweep there would take a
// live co-tenant's record down with ours. The orphan is the lesser failure, and
// it is loud in the zone rather than silent on someone else's running site.
func instTeardownDNS(ctx context.Context, dns *hcloud.Client, zone, label, ip string, exclusive bool) ([]string, error) {
	// The by-name delete ALWAYS fires, sweep or no sweep. It is strictly the old
	// behaviour and it is not redundant: a platform record whose value has
	// drifted off the box IP (a hand-repointed A, a stale row) is invisible to a
	// by-value sweep, and dropping the name delete in favour of the sweep would
	// have made this teardown NARROWER than the one it replaces. Idempotent —
	// absent is a no-op — so it costs one call.
	if derr := instDeleteA(ctx, dns, zone, label); derr != nil {
		return nil, derr
	}
	deleted := []string{hzRRSetName(label)}
	if strings.TrimSpace(ip) == "" || !exclusive {
		return deleted, nil
	}
	swept, serr := instSweepAByValue(ctx, dns, zone, ip)
	for _, n := range swept {
		if n != hzRRSetName(label) {
			deleted = append(deleted, n)
		}
	}
	return deleted, serr
}

// instLookupA returns the A values currently at label.zone (nil when absent).
func instLookupA(ctx context.Context, dns *hcloud.Client, zone, label string) ([]string, error) {
	rrsets, err := dns.Zone.AllRRSets(ctx, hzZoneRef(zone))
	if err != nil {
		return nil, err
	}
	want := hzRRSetName(label)
	var values []string
	for _, rr := range rrsets {
		if rr.Name == want && rr.Type == hcloud.ZoneRRSetTypeA {
			for _, rec := range rr.Records {
				values = append(values, rec.Value)
			}
		}
	}
	return values, nil
}

// instHealthPin controls whether the health probe dials the box's IP directly
// (TLS SNI still carries the fqdn). True in production: the A record was
// (re)written SECONDS ago, so public resolvers may still hold a negative-cache
// NXDOMAIN for it — system DNS would fail a perfectly healthy box. Tests flip
// it off so their instHTTP stub sees the probe.
var instHealthPin = true

// instHealth polls https://fqdn/api/schemas until it answers 200 — the same
// smoke the deploy runbook mandates. Bounded by instPoll × instPollMax. When
// ip is known the connection is pinned to it (see instHealthPin).
func instHealth(fqdn, ip string) error {
	client := instHTTP
	if ip != "" && instHealthPin {
		dialer := &net.Dialer{Timeout: 10 * time.Second}
		client = &http.Client{
			Timeout: instHTTP.Timeout,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
					if host, port, err := net.SplitHostPort(addr); err == nil && strings.EqualFold(host, fqdn) {
						return dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
					}
					return dialer.DialContext(ctx, network, addr)
				},
			},
		}
	}
	url := "https://" + fqdn + "/api/schemas"
	var last error
	for i := 0; i < instPollMax; i++ {
		resp, err := client.Get(url)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			last = fmt.Errorf("HTTP %d", resp.StatusCode)
		} else {
			last = err
		}
		time.Sleep(instPoll)
	}
	return fmt.Errorf("%s never answered 200 (%v)", url, last)
}

// instCreateFromArchive boots a new managed box from an archive image,
// stamping the fleet labels, and waits until it is running with a public IP.
func instCreateFromArchive(ctx context.Context, out *writer, hc *hcloud.Client, img *hcloud.Image, name, fqdn, typ, loc, sshKey string) (*hcloud.Server, error) {
	if typ == "" {
		typ = img.Labels[instArchiveTypeKey]
	}
	if loc == "" {
		loc = img.Labels[instArchiveLocKey]
	}
	if typ == "" {
		return nil, fmt.Errorf("archive %d carries no %s label — pass --type", img.ID, instArchiveTypeKey)
	}
	opts := hcloud.ServerCreateOpts{
		Name:       name,
		ServerType: hzServerTypeRef(typ),
		Image:      &hcloud.Image{ID: img.ID},
		Labels: map[string]string{
			cloud.ManagedLabelKey: "true",
			cloud.FQDNLabelKey:    fqdn,
		},
	}
	if loc != "" {
		opts.Location = &hcloud.Location{Name: loc}
	}
	// An ssh key is NOT optional: a keyless create makes Hetzner mint a root
	// password and EXPIRE it on first boot, after which PAM refuses every
	// non-interactive session — the restored box would be healthy but
	// unreachable to every SSH-based verb (export, --stop, clone-swap).
	// Resolution mirrors the provisioner: flag > BARKPARK_SSH_KEY > the
	// project's sole key.
	if sshKey == "" {
		sshKey = strings.TrimSpace(os.Getenv("BARKPARK_SSH_KEY"))
	}
	if sshKey == "" {
		all, kerr := hc.SSHKey.All(ctx)
		if kerr != nil {
			return nil, fmt.Errorf("list ssh keys: %w", kerr)
		}
		if len(all) != 1 {
			return nil, fmt.Errorf("pass --ssh-key or set BARKPARK_SSH_KEY: the project has %d ssh keys (need exactly one to auto-select)", len(all))
		}
		opts.SSHKeys = all
	} else {
		keys, err := resolveHzSSHKeys(ctx, hc, []string{sshKey})
		if err != nil {
			return nil, err
		}
		opts.SSHKeys = keys
	}
	result, _, err := hc.Server.Create(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("create %s from archive %d: %w", name, img.ID, err)
	}
	out.info("server %s accepted — waiting for boot…", name)
	actions := append([]*hcloud.Action{result.Action}, result.NextActions...)
	if err := hzWait(ctx, hc, actions...); err != nil {
		return nil, fmt.Errorf("create %s: action failed: %w", name, err)
	}
	srv := result.Server
	for i := 0; i < hetznerCreatePollMax; i++ {
		if srv != nil && srv.Status == hcloud.ServerStatusRunning && hzIPv4(srv) != "" {
			break
		}
		time.Sleep(hetznerCreatePoll)
		fresh, _, gerr := hc.Server.GetByID(ctx, result.Server.ID)
		if gerr != nil {
			return nil, fmt.Errorf("create %s: read-back: %w", name, gerr)
		}
		if fresh != nil {
			srv = fresh
		}
	}
	if srv == nil || srv.Status != hcloud.ServerStatusRunning || hzIPv4(srv) == "" {
		return nil, fmt.Errorf("create %s: created but never reached running with an IP", name)
	}
	return srv, nil
}

// instObserveImage renders the image half of a create-from-archive receipt out
// of what the POLLED server reports, keeping the requested archive under a name
// that says it is a request. hzObserveImage supplies the observed half (and the
// image_observed: false it emits when the read-back carries no image at all,
// which is the honest answer — not a fallback to the id that was asked for).
//
// The disagreement key exists because the only interesting case is the one the
// old receipt could not express: a box that came up on an image nobody asked
// for. An operator who resurrects from archive 777 and reads image_id: 700 has
// a wrong box; an operator reading the request back at himself has no way to
// find that out.
func instObserveImage(srv *hcloud.Server, requested *hcloud.Image) map[string]any {
	row := hzObserveImage(srv)
	if requested != nil {
		row["requested_image_id"] = requested.ID
		if srv != nil && srv.Image != nil && srv.Image.ID != requested.ID {
			row["image_disagreement"] = fmt.Sprintf(
				"booted from archive %d but the box reports image %d", requested.ID, srv.Image.ID)
		}
	}
	return row
}

// instDeleteServer deletes srv, re-checking the fqdn guard first: never delete
// a box whose barkpark-fqdn label names a DIFFERENT identity than the one the
// operator targeted (the DeprovisionByIP fence, ported).
func instDeleteServer(ctx context.Context, hc *hcloud.Client, srv *hcloud.Server, fqdn string, force bool) error {
	if !force {
		if got := srv.Labels[cloud.FQDNLabelKey]; got != "" && got != fqdn {
			return fmt.Errorf("server %s is labeled %s=%q, not %q — refusing to delete (pass --force to override)", srv.Name, cloud.FQDNLabelKey, got, fqdn)
		}
	}
	result, _, err := hc.Server.DeleteWithResult(ctx, srv)
	if err != nil {
		return fmt.Errorf("delete server %s: %w", srv.Name, err)
	}
	if err := hzWait(ctx, hc, result.Action); err != nil {
		return fmt.Errorf("delete server %s: action failed: %w", srv.Name, err)
	}
	return nil
}

// instServerName derives a fresh, deterministic box name for a clone/restore:
// bp-<label>-r<image id> (the image id is unique per archive, so a retry after
// a partial failure reuses the SAME name instead of leaking a second box).
func instServerName(label string, img *hcloud.Image) string {
	return "bp-" + label + "-r" + strconv.FormatInt(img.ID, 10)
}

// ---------------------------------------------------------------------------
// archive / archives
// ---------------------------------------------------------------------------

func runInstanceArchive(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance archive <fqdn|server> [--zone <z>] [--fqdn <f>] [--stop]"
	a, err := parseHzArgs(args, []string{"zone", "fqdn"}, []string{"stop"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|server> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, fqdn, terr := instTarget(ctx, hc, a.pos[0], zone, a.val("fqdn"))
	if terr != nil {
		return hzFail(out, "archive", terr)
	}
	if srv == nil {
		return useError(out, "failed", "archive "+fqdn+": no server carries that identity (see `bp cloud hetzner instance audit`)", exitNotFound)
	}
	obs, aerr := instArchive(ctx, out, hc, srv, fqdn, a.bools["stop"])
	if aerr != nil {
		return hzFail(out, "archive "+fqdn, aerr)
	}
	extra := obs.receipt()
	extra["fqdn"] = fqdn
	return hzDone(out, "archive", srv, extra)
}

func runInstanceArchives(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance archives [<fqdn>] [--zone <z>]"
	a, err := parseHzArgs(args, []string{"zone"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	fqdn := ""
	if len(a.pos) == 1 {
		fqdn = strings.Trim(strings.TrimSpace(a.pos[0]), ".")
		if !strings.Contains(fqdn, ".") {
			fqdn = fqdn + "." + zone
		}
	} else if len(a.pos) > 1 {
		return useError(out, "usage", "at most one <fqdn> (usage: "+usage+")", exitUsage)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	images, lerr := instArchivesFor(hetznerCtx(), c.HCloud(), fqdn)
	if lerr != nil {
		return hzFail(out, "list archives", lerr)
	}
	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(images))
		for _, img := range images {
			row := map[string]any{
				"id":      img.ID,
				"fqdn":    img.Labels[cloud.FQDNLabelKey],
				"created": img.Created.UTC().Format(time.RFC3339),
				"type":    img.Labels[instArchiveTypeKey],
			}
			if img.ImageSize != 0 {
				row["size_gb"] = img.ImageSize
			}
			rows = append(rows, row)
		}
		out.emitStructured(map[string]any{"archives": rows})
		return exitOK
	}
	if len(images) == 0 {
		out.outf("no archives — create one with `bp cloud hetzner instance archive <fqdn>`")
		return exitOK
	}
	rows := make([][]string, 0, len(images))
	for _, img := range images {
		size := ""
		if img.ImageSize != 0 {
			size = fmt.Sprintf("%.2f GB", img.ImageSize)
		}
		rows = append(rows, []string{
			strconv.FormatInt(img.ID, 10),
			hzCell(img.Labels[cloud.FQDNLabelKey]),
			hzCell(img.Labels[instArchiveTypeKey]),
			hzCell(size),
			hzCell(img.Created.UTC().Format(time.RFC3339)),
		})
	}
	renderHzTable(out, []string{"IMAGE", "FQDN", "TYPE", "SIZE", "CREATED"}, rows)
	return exitOK
}

// ---------------------------------------------------------------------------
// decommission
// ---------------------------------------------------------------------------

func runInstanceDecommission(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance decommission <fqdn|server> [--zone <z>] [--fqdn <f>] [--no-archive] [--direct] [--force] [--yes] [--dns-token <t>] [--control-url <u>] [--worker-token <t>]"
	a, err := parseHzArgs(args,
		[]string{"zone", "fqdn", "dns-token", "control-url", "worker-token"},
		[]string{"no-archive", "direct", "force", "yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|server> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()

	srv, fqdn, terr := instTarget(ctx, hc, a.pos[0], zone, a.val("fqdn"))
	if terr != nil {
		return hzFail(out, "decommission", terr)
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}

	// The typed-name gate covers the WHOLE teardown (server + DNS + registry
	// row), so it fires before the archive quiesces the box — the first
	// disruptive step, not just the first delete.
	if cerr := hzConfirmDestroy(hzStdin, out, "instance", fqdn, a.bools["yes"]); cerr != nil {
		return hzConfirmAbort(out, cerr)
	}

	report := map[string]any{"fqdn": fqdn}

	// The box address the DNS verify matches record VALUES against. Set by the
	// direct-teardown arm below; empty on the registry arm (the worker swept by
	// value itself and the box is already gone), where the by-name check stands.
	verifyIP := ""

	// 1. Archive first — nothing is destroyed before the resurrection point
	//    exists. Data writers are stopped (the box is about to die anyway).
	if srv != nil && !a.bools["no-archive"] {
		obs, aerr := instArchive(ctx, out, hc, srv, fqdn, true)
		if aerr != nil {
			return hzFail(out, "decommission "+fqdn, aerr)
		}
		report["archive_image_id"] = obs.image.ID
		report["archive_quiesced"] = obs.quiesced
		// decommission DESTROYS the box, so this archive is the only
		// resurrection point there will be — and unlike adopt/eject, nothing
		// downstream boots from it to prove it works. If instArchive could not
		// settle the image read, the receipt must say so here too; carrying the
		// id alone would assert a restorable archive nobody confirmed.
		if obs.confirm != "" {
			report["archive_confirmation"] = "unavailable"
			report["archive_confirmation_error"] = obs.confirm
		} else {
			report["archive_image_status"] = obs.status
		}
	}

	// 2. Registry row: prefer the control plane's own deprovision queue. When
	//    the row's host is a recycled IP owned by a DIFFERENT identity, the
	//    worker's fence would (rightly) refuse — that stale row is detached
	//    registry-only instead.
	cp := instCP(a)
	registryHandled := false
	if cp != nil && !a.bools["direct"] {
		rows, lerr := cp.List()
		if lerr != nil {
			return useError(out, "failed", "decommission "+fqdn+": "+lerr.Error(), exitGeneric)
		}
		ip := ""
		if srv != nil {
			ip = hzIPv4(srv)
		}
		row := cpFindRow(rows, label, fzone, ip)
		if row == nil {
			out.info("no registry row for %s — infra-only teardown", fqdn)
		} else {
			detach := false
			if row.Host != "" && (srv == nil || row.Host != hzIPv4(srv)) {
				// The row claims an IP that is not this instance's box: a
				// recycled IP (or a box we cannot see). If a managed server
				// owns that IP under another identity, the worker fence would
				// fail the job — detach the row instead of tripping it.
				detach = instIPOwnedByOther(ctx, hc, row.Host, fqdn)
			}
			status, derr := cp.Deprovision(row.ID, detach)
			if derr != nil {
				return useError(out, "failed", "decommission "+fqdn+": "+derr.Error(), exitGeneric)
			}
			report["registry"] = status
			if status == "deprovisioning" {
				out.info("worker is tearing %s down (job status: deprovisioning) — waiting…", fqdn)
				if werr := instWaitRowGone(cp, row.ID); werr != nil {
					return useError(out, "failed", "decommission "+fqdn+": "+werr.Error(), exitGeneric)
				}
				// The worker deleted the box + DNS; nothing left for step 3.
				registryHandled = true
			}
			// status "removed": the row is gone but the box/DNS (if any) are
			// still ours to clean below.
		}
	} else if cp == nil {
		out.info("no WORKER_TOKEN — registry row (if any) is NOT touched; direct infra teardown only")
	}

	// 3. Direct teardown of whatever survives: the box (fqdn-fenced) and the
	//    A record.
	if !registryHandled {
		// The box IP is read BEFORE the server goes — it is the only handle the
		// by-value sweep below has, and a deleted server no longer carries it.
		// The exclusivity fence is answered here too, while the co-tenant (if
		// any) is still listable (task-688ebffc4b0aa50a).
		boxIP, sweepExclusive := "", false
		if srv != nil {
			boxIP = hzIPv4(srv)
			sweepExclusive = boxIP != "" && !instIPOwnedByOther(ctx, hc, boxIP, fqdn)
		}
		if srv != nil {
			if derr := instDeleteServer(ctx, hc, srv, fqdn, a.bools["force"]); derr != nil {
				return useError(out, "failed", "decommission "+fqdn+": "+derr.Error(), exitGeneric)
			}
			report["server_deleted"] = srv.Name
		}
		// BY VALUE, not name: the go-live `<slug>-<teamid>` sibling and any
		// attached custom host live at this same address and would otherwise
		// outlive the box at an IP about to be reassigned.
		swept, derr := instTeardownDNS(ctx, dns, fzone, label, boxIP, sweepExclusive)
		if derr != nil {
			return useError(out, "failed", "decommission "+fqdn+": "+derr.Error(), exitGeneric)
		}
		report["dns_deleted"] = swept
		if boxIP != "" && !sweepExclusive {
			out.errf("⚠ dns: %s is shared with another managed box (or its address is unknown) — swept BY NAME only; a sibling A record at that address may survive", fqdn)
		}
		verifyIP = boxIP
	}

	// 4. VERIFY no residue — the whole point. Any survivor is a non-zero exit.
	residue := instVerifyGone(ctx, hc, dns, cp, fqdn, label, fzone, verifyIP)
	report["residue"] = residue
	report["ok"] = len(residue) == 0
	if out.emitStructured(report) {
		if len(residue) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	if len(residue) > 0 {
		out.outf("✗ decommission %s left residue:", fqdn)
		for _, r := range residue {
			out.outf("  - %s", r)
		}
		return exitGeneric
	}
	out.outf("✓ decommission %s — no residue (server, DNS and registry all clean)", fqdn)
	if id, ok := report["archive_image_id"]; ok {
		out.outf("  archive: image %v (resurrect with `bp cloud hetzner instance resurrect %s`)", id, fqdn)
	}
	return exitOK
}

// instIPOwnedByOther reports whether ip belongs to a managed server whose
// barkpark-fqdn label names an identity OTHER than fqdn.
func instIPOwnedByOther(ctx context.Context, hc *hcloud.Client, ip, fqdn string) bool {
	servers, err := hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: cloud.ManagedLabelKey + "=true"},
	})
	if err != nil {
		return false
	}
	for _, s := range servers {
		if hzIPv4(s) == ip && s.Labels[cloud.FQDNLabelKey] != fqdn {
			return true
		}
	}
	return false
}

// instWaitRowGone polls the registry until the row disappears (worker done) or
// its deprovision job reports failed.
func instWaitRowGone(cp *cpFleet, id string) error {
	for i := 0; i < instPollMax; i++ {
		rows, err := cp.List()
		if err != nil {
			return err
		}
		var row *cpBarkpark
		for j := range rows {
			if rows[j].ID == id {
				row = &rows[j]
				break
			}
		}
		if row == nil {
			return nil
		}
		if row.DeprovisionStatus == "failed" {
			return fmt.Errorf("the worker's deprovision job FAILED — see the control plane's job console")
		}
		time.Sleep(instPoll)
	}
	return fmt.Errorf("registry row still present after %s — the worker may be stuck", time.Duration(instPollMax)*instPoll)
}

// instVerifyGone re-reads all three surfaces and lists every survivor.
func instVerifyGone(ctx context.Context, hc *hcloud.Client, dns *hcloud.Client, cp *cpFleet, fqdn, label, zone, ip string) []string {
	var residue []string
	servers, err := hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: cloud.ManagedLabelKey + "=true"},
	})
	if err == nil {
		for _, s := range servers {
			if s.Labels[cloud.FQDNLabelKey] == fqdn {
				residue = append(residue, fmt.Sprintf("server %s (id %d) still exists", s.Name, s.ID))
			}
		}
	} else {
		residue = append(residue, "could not verify servers: "+err.Error())
	}
	values, derr := instLookupA(ctx, dns, zone, label)
	if derr != nil {
		residue = append(residue, "could not verify DNS: "+derr.Error())
	} else if len(values) > 0 {
		residue = append(residue, fmt.Sprintf("DNS A %s.%s still resolves to %s", label, zone, strings.Join(values, ", ")))
	}
	// BY VALUE (task-688ebffc4b0aa50a, PDF-D101): the by-name check above reads
	// clean while the go-live `<label>-<teamid>` sibling — or an attached custom
	// host — still points at the released address. The VALUE is the truth, so a
	// survivor is NAMED here instead of silently passing as delta zero.
	if strings.TrimSpace(ip) != "" {
		names, verr := instARecordNamesByValue(ctx, dns, zone, ip)
		if verr != nil {
			residue = append(residue, "could not verify DNS by value: "+verr.Error())
		} else {
			for _, n := range names {
				if n == hzRRSetName(label) {
					continue // already reported by the by-name check above
				}
				residue = append(residue, fmt.Sprintf("DNS A %s still resolves to the released box IP %s", cloud.Fqdn(hzLabelOfRRSetName(n), zone), ip))
			}
		}
	}
	if cp != nil {
		rows, lerr := cp.List()
		if lerr != nil {
			residue = append(residue, "could not verify registry: "+lerr.Error())
		} else if row := cpFindRow(rows, label, zone, ""); row != nil {
			residue = append(residue, fmt.Sprintf("registry row %s (%s) still exists", row.ID, row.Slug))
		}
	}
	return residue
}

// ---------------------------------------------------------------------------
// resurrect
// ---------------------------------------------------------------------------

func runInstanceResurrect(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance resurrect <fqdn> [--zone <z>] [--image <id>] [--name <n>] [--type <t>] [--location <l>] [--ssh-key <k>] [--no-health] [--dns-token <t>]"
	a, err := parseHzArgs(args,
		[]string{"zone", "image", "name", "type", "location", "ssh-key", "dns-token"},
		[]string{"no-health"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	fqdn := strings.Trim(strings.TrimSpace(a.pos[0]), ".")
	if !strings.Contains(fqdn, ".") {
		fqdn = fqdn + "." + zone
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()

	// Refuse to resurrect over a live twin — that would leave two boxes
	// fighting for one DNS name.
	if existing, _, terr := instTarget(ctx, hc, fqdn, zone, ""); terr == nil && existing != nil {
		return useError(out, "failed", fmt.Sprintf("resurrect %s: server %s already carries that identity — decommission it first", fqdn, existing.Name), exitConflict)
	}

	var img *hcloud.Image
	if ref := a.val("image"); ref != "" {
		id, perr := strconv.ParseInt(ref, 10, 64)
		if perr != nil {
			return useError(out, "usage", "--image wants a numeric image id", exitUsage)
		}
		found, _, gerr := hc.Image.GetByID(ctx, id)
		if gerr != nil || found == nil {
			return useError(out, "failed", fmt.Sprintf("resurrect %s: image %d not found", fqdn, id), exitNotFound)
		}
		img = found
	} else {
		images, lerr := instArchivesFor(ctx, hc, fqdn)
		if lerr != nil {
			return hzFail(out, "resurrect "+fqdn, lerr)
		}
		if len(images) == 0 {
			return useError(out, "failed", "resurrect "+fqdn+": no archive images carry that fqdn (see `bp cloud hetzner instance archives`)", exitNotFound)
		}
		img = images[0]
	}

	name := a.val("name")
	if name == "" {
		name = instServerName(label, img)
	}
	srv, cerr := instCreateFromArchive(ctx, out, hc, img, name, fqdn, a.val("type"), a.val("location"), a.val("ssh-key"))
	if cerr != nil {
		return useError(out, "failed", "resurrect "+fqdn+": "+cerr.Error(), exitGeneric)
	}
	ip := hzIPv4(srv)
	if derr := instUpsertA(ctx, dns, fzone, label, ip); derr != nil {
		return useError(out, "failed", "resurrect "+fqdn+": box is up at "+ip+" but DNS failed: "+derr.Error(), exitGeneric)
	}
	// THE IMAGE HALF OF THIS RECEIPT IS A READ-BACK, NOT THE REQUEST. `img` is
	// the archive this verb ASKED Hetzner to boot; what the resurrected box
	// actually runs is whatever the running+IPv4 poll inside
	// instCreateFromArchive read back off the server. On every honest create
	// those are the same id — which is exactly why printing the request as
	// though it were the observation went unnoticed: it is right until the one
	// time it is not. So `image_id` now carries the OBSERVED id, the requested
	// archive rides under its own name, and a disagreement is reported.
	extra := map[string]any{"fqdn": fqdn, "ipv4": ip}
	for k, v := range instObserveImage(srv, img) {
		extra[k] = v
	}
	if a.bools["no-health"] {
		// SILENCE IS NOT A SKIP. An omitted `health` key is indistinguishable
		// from a receipt written before the key existed, and from a probe that
		// crashed — three different worlds rendered as the same absence.
		// --no-health is the operator declining the post-condition, so the
		// receipt says that in its own words and stays a ✓ for what it did do.
		extra["health"] = "skipped (--no-health)"
	} else {
		out.info("waiting for https://%s/api/schemas …", fqdn)
		if herr := instHealth(fqdn, ip); herr != nil {
			extra["health"] = "FAILED: " + herr.Error()
			payload := map[string]any{"ok": false, "action": "resurrect", "server": map[string]any{"id": srv.ID, "name": srv.Name}}
			for k, v := range extra {
				payload[k] = v
			}
			if out.emitStructured(payload) {
				return exitGeneric
			}
			out.outf("✗ resurrect %s — box %s is up at %s but the health gate failed: %v", fqdn, srv.Name, ip, herr)
			return exitGeneric
		}
		extra["health"] = "ok"
	}
	extra["note"] = "infra-level restore — the control-plane registry row (if this was a tenant) is NOT recreated; use `instance adopt` to register it"
	return hzDone(out, "resurrect", srv, extra)
}

// ---------------------------------------------------------------------------
// adopt (standalone → SaaS tenant) and eject (tenant → standalone)
// ---------------------------------------------------------------------------

// instCloneSwap is the shared engine of adopt/eject: archive the current box,
// boot a clone from that archive, repoint DNS at the clone, health-gate, then
// destroy the old box. Returns the clone and what the archive OBSERVED (the
// callers' receipts report the archive's quiesce state, not just its id). The
// fqdn (and so the on-box Caddy/PHX_HOST config) is deliberately UNCHANGED —
// that is what makes the swap zero-reconfig.
func instCloneSwap(ctx context.Context, out *writer, hc *hcloud.Client, dns *hcloud.Client, srv *hcloud.Server, fqdn, sshKey string, keepOld bool) (*hcloud.Server, *instArchiveObs, error) {
	label, fzone := instLabelOf(fqdn)
	obs, err := instArchive(ctx, out, hc, srv, fqdn, true)
	if err != nil {
		return nil, nil, err
	}
	img := obs.image
	// Placement comes from the live source box, not the image labels — the
	// clone must match the box it replaces even if the archive predates it.
	typ := ""
	if srv.ServerType != nil {
		typ = srv.ServerType.Name
	}
	clone, err := instCreateFromArchive(ctx, out, hc, img, instServerName(label, img), fqdn, typ, hzServerLocation(srv), sshKey)
	if err != nil {
		return nil, obs, err
	}
	if err := instUpsertA(ctx, dns, fzone, label, hzIPv4(clone)); err != nil {
		return clone, obs, fmt.Errorf("clone %s is up at %s but DNS failed: %w", clone.Name, hzIPv4(clone), err)
	}
	out.info("waiting for https://%s/api/schemas on the clone…", fqdn)
	if err := instHealth(fqdn, hzIPv4(clone)); err != nil {
		return clone, obs, fmt.Errorf("clone %s is up but the health gate failed: %w (old box %s left untouched)", clone.Name, err, srv.Name)
	}
	if !keepOld {
		if err := instDeleteServer(ctx, hc, srv, fqdn, true); err != nil {
			return clone, obs, fmt.Errorf("clone is serving but deleting the old box failed: %w", err)
		}
	}
	return clone, obs, nil
}

func runInstanceAdopt(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance adopt <fqdn|server> --team <team-id> [--name <n>] [--admin-token <t>] [--zone <z>] [--ssh-key <k>] [--keep-old] [--dns-token <t>] [--control-url <u>] [--worker-token <t>]"
	a, err := parseHzArgs(args,
		[]string{"team", "name", "admin-token", "zone", "ssh-key", "dns-token", "control-url", "worker-token", "fqdn"},
		[]string{"keep-old"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 || a.val("team") == "" {
		return useError(out, "usage", "want <fqdn|server> and --team <team-id> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	cp := instCP(a)
	if cp == nil {
		return useError(out, "auth", "adopt needs the control plane — set WORKER_TOKEN (or --worker-token)", exitAuth)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, fqdn, terr := instTarget(ctx, hc, a.pos[0], zone, a.val("fqdn"))
	if terr != nil {
		return hzFail(out, "adopt", terr)
	}
	if srv == nil {
		return useError(out, "failed", "adopt "+fqdn+": no server carries that identity", exitNotFound)
	}
	label, _ := instLabelOf(fqdn)
	if !strings.HasSuffix(fqdn, "."+zone) {
		return useError(out, "failed", fmt.Sprintf("adopt %s: v1 adoption keeps the fqdn, so it must live under the fleet zone %s", fqdn, zone), exitUsage)
	}

	clone, obs, serr := instCloneSwap(ctx, out, hc, dns, srv, fqdn, a.val("ssh-key"), a.bools["keep-old"])
	if serr != nil {
		return useError(out, "failed", "adopt "+fqdn+": "+serr.Error(), exitGeneric)
	}

	name := a.val("name")
	if name == "" {
		name = label
	}
	attrs := map[string]string{
		"team_id": a.val("team"),
		"name":    name,
		"slug":    label,
		"url":     "https://" + fqdn,
		"host":    hzIPv4(clone),
	}
	if t := a.val("admin-token"); t != "" {
		attrs["admin_token"] = t
	}
	row, aerr := cp.Adopt(attrs)
	if aerr != nil {
		return useError(out, "failed", "adopt "+fqdn+": clone "+clone.Name+" is serving but registration failed: "+aerr.Error(), exitGeneric)
	}
	extra := map[string]any{
		"fqdn":             fqdn,
		"ipv4":             hzIPv4(clone),
		"archive_image_id": obs.image.ID,
		"archive_quiesced": obs.quiesced,
	}

	// THE POST-CONDITION, and why adopt may not report registry_id on a 201
	// alone — the same argument eject already makes about its detach, one
	// resource over. cp.Adopt's 201 body is the control plane REPEATING the
	// attrs it was handed; a plane that validated the payload, answered 201 and
	// wrote no row produces a byte-identical receipt to one that adopted the
	// box. So does a plane that recorded the row against the OLD box's IP,
	// which strands the dashboard on a machine instCloneSwap just destroyed.
	// The claim "this box is now a managed tenant" is earned by re-reading the
	// registry: the row the plane named is present, and its host is the clone's
	// IPv4. Anything else is an unconfirmed registration — not a failed verb
	// (the clone is serving and DNS points at it) and NOT a silent ✓ either, so
	// it takes hzPartial's confirmation-unavailable shape and sends the
	// operator to look.
	clonedIP := hzIPv4(clone)
	unconfirmed := ""
	rows, lerr := cp.List()
	switch {
	case lerr != nil:
		extra["confirmation_error"] = lerr.Error()
		unconfirmed = "the control plane accepted the registration but the registry could not be re-read to confirm the row exists"
	default:
		switch got := cpRowByID(rows, row.ID); {
		case got == nil:
			unconfirmed = fmt.Sprintf("the control plane answered 201 with registry row %q, but a fresh read of the "+
				"registry does not carry it — nothing is managing this instance", row.ID)
		case got.Host != clonedIP:
			unconfirmed = fmt.Sprintf("registry row %s exists but its host is %q, not the clone's %s — the dashboard "+
				"would drive a box this adopt already destroyed", got.ID, got.Host, clonedIP)
		default:
			extra["registry_id"] = got.ID
			extra["team_id"] = got.TeamID
			extra["registry_host"] = got.Host
		}
	}
	if unconfirmed != "" {
		extra["confirmation"] = "unavailable"
		extra["adopt_reported_id"] = row.ID
		return hzPartial(out, "adopt", clone, unconfirmed+" — re-check with `bp cloud hetzner instance audit`", extra)
	}
	extra["note"] = "registered — the row is present in a fresh registry read and its host is the clone"
	return hzDone(out, "adopt", clone, extra)
}

func runInstanceEject(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance eject <fqdn|slug|server> [--zone <z>] [--ssh-key <k>] [--keep-old] [--dns-token <t>] [--control-url <u>] [--worker-token <t>]"
	a, err := parseHzArgs(args,
		[]string{"zone", "ssh-key", "dns-token", "control-url", "worker-token", "fqdn"},
		[]string{"keep-old"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", "want exactly one <fqdn|slug|server> (usage: "+usage+")", exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	cp := instCP(a)
	if cp == nil {
		return useError(out, "auth", "eject needs the control plane — set WORKER_TOKEN (or --worker-token)", exitAuth)
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()
	srv, fqdn, terr := instTarget(ctx, hc, a.pos[0], zone, a.val("fqdn"))
	if terr != nil {
		return hzFail(out, "eject", terr)
	}
	if srv == nil {
		return useError(out, "failed", "eject "+fqdn+": no server carries that identity", exitNotFound)
	}
	label, fzone := instLabelOf(fqdn)
	if fzone == "" {
		fzone = zone
	}
	rows, lerr := cp.List()
	if lerr != nil {
		return useError(out, "failed", "eject "+fqdn+": "+lerr.Error(), exitGeneric)
	}
	row := cpFindRow(rows, label, fzone, hzIPv4(srv))
	if row == nil {
		return useError(out, "failed", "eject "+fqdn+": no registry row — it is already standalone", exitNotFound)
	}

	clone, obs, serr := instCloneSwap(ctx, out, hc, dns, srv, fqdn, a.val("ssh-key"), a.bools["keep-old"])
	if serr != nil {
		return useError(out, "failed", "eject "+fqdn+": "+serr.Error(), exitGeneric)
	}

	// The clone is standalone: detach the row registry-only (the worker must
	// NOT tear the clone down — that's the whole point).
	status, derr := cp.Deprovision(row.ID, true)
	if derr != nil {
		return useError(out, "failed", "eject "+fqdn+": clone "+clone.Name+" is serving but the registry detach failed: "+derr.Error(), exitGeneric)
	}
	extra := map[string]any{
		"fqdn":             fqdn,
		"ipv4":             hzIPv4(clone),
		"archive_image_id": obs.image.ID,
		"archive_quiesced": obs.quiesced,
		"registry_detach":  status,
	}

	// THE POST-CONDITION, and why eject may not report on err == nil alone.
	// Deprovision RETURNS the status the control plane chose ("removed" |
	// "deprovisioning"); a control plane that ignored the detach key answers
	// 200 with "deprovisioning" and enqueues a worker teardown — of the clone
	// this verb just built. So the claim "now standalone" is earned by TWO
	// observations: the returned status is "removed", and the row is gone from
	// a fresh cp.List(). Anything else is an unconfirmed detach: not a failed
	// verb (the clone is serving) and NOT a silent ✓ either — it takes the
	// same hzPartial / confirmation-unavailable shape runHetznerServerAction
	// takes when only the confirming read fails, so the operator is told to
	// look rather than told a fact nobody checked.
	unconfirmed := ""
	if status != "removed" {
		unconfirmed = fmt.Sprintf("the control plane accepted the detach but reports status %q, not \"removed\" — "+
			"a worker deprovision job may be en route to tear down the clone this eject just built", status)
	} else if rows, lerr := cp.List(); lerr != nil {
		extra["confirmation_error"] = lerr.Error()
		unconfirmed = "the detach reported \"removed\" but the registry could not be re-read to confirm the row is gone"
	} else if still := cpFindRow(rows, label, fzone, hzIPv4(srv)); still != nil {
		unconfirmed = fmt.Sprintf("the detach reported \"removed\" but registry row %s is still present — "+
			"the control plane may still manage this instance", still.ID)
	}
	if unconfirmed != "" {
		extra["confirmation"] = "unavailable"
		return hzPartial(out, "eject", clone, unconfirmed+" — re-check with `bp cloud hetzner instance audit`", extra)
	}
	extra["registry_row"] = "gone"
	extra["note"] = "now standalone — the control plane no longer manages it (detach reported removed and the row is gone)"
	return hzDone(out, "eject", clone, extra)
}

// ---------------------------------------------------------------------------
// audit
// ---------------------------------------------------------------------------

func runInstanceAudit(out *writer, g globals, args []string) int {
	const usage = "bp cloud hetzner instance audit [--zone <z>] [--external <label,…>] [--dns-token <t>] [--control-url <u>] [--worker-token <t>]"
	a, err := parseHzArgs(args, []string{"zone", "external", "dns-token", "control-url", "worker-token"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	zone := a.val("zone")
	if zone == "" {
		zone = instDefaultZone
	}
	// Known-external DNS labels (--external, else BARKPARK_AUDIT_EXTERNAL):
	// records that legitimately point outside the managed fleet — the apex,
	// www/api/mail on the control plane, a standalone in another project.
	// They are counted, not reported, so the exit-code gate stays meaningful.
	external := map[string]bool{}
	externalSrc := a.list("external")
	if len(externalSrc) == 0 {
		for _, l := range strings.Split(os.Getenv("BARKPARK_AUDIT_EXTERNAL"), ",") {
			if l = strings.TrimSpace(l); l != "" {
				externalSrc = append(externalSrc, l)
			}
		}
	}
	for _, l := range externalSrc {
		external[hzRRSetName(l)] = true
	}
	c, ok := hetznerClient(out, g)
	if !ok {
		return exitAuth
	}
	dnsUsesComputeToken := instDNSUsesComputeToken(a)
	dns, ok := instDNSClient(out, g, a)
	if !ok {
		return exitAuth
	}
	ctx := hetznerCtx()
	hc := c.HCloud()

	servers, serr := hc.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{LabelSelector: cloud.ManagedLabelKey + "=true"},
	})
	if serr != nil {
		return hzFail(out, "audit: list servers", serr)
	}
	rrsets, derr := dns.Zone.AllRRSets(ctx, hzZoneRef(zone))
	if derr != nil {
		return hzDNSFail(out, "audit: list dns records", derr, dnsUsesComputeToken)
	}
	var rows []cpBarkpark
	cp := instCP(a)
	if cp != nil {
		var lerr error
		rows, lerr = cp.List()
		if lerr != nil {
			return useError(out, "failed", "audit: "+lerr.Error(), exitGeneric)
		}
	}
	archives, aerr := instArchivesFor(ctx, hc, "")
	if aerr != nil {
		return hzFail(out, "audit: list archives", aerr)
	}

	byFqdn := map[string]*hcloud.Server{}
	byIP := map[string]*hcloud.Server{}
	for _, s := range servers {
		if f := s.Labels[cloud.FQDNLabelKey]; f != "" {
			byFqdn[f] = s
		}
		if ip := hzIPv4(s); ip != "" {
			byIP[ip] = s
		}
	}
	archiveCount := map[string]int{}
	for _, img := range archives {
		archiveCount[img.Labels[cloud.FQDNLabelKey]]++
	}

	type finding struct {
		Kind   string `json:"kind"`
		Who    string `json:"who"`
		Detail string `json:"detail"`
	}
	var findings []finding

	// Servers: every managed box should have its A record (and a row when the
	// control plane is reachable).
	for _, s := range servers {
		fqdn := s.Labels[cloud.FQDNLabelKey]
		if fqdn == "" {
			findings = append(findings, finding{"unlabeled-server", s.Name, "managed box with no " + cloud.FQDNLabelKey + " label"})
			continue
		}
		label, fzone := instLabelOf(fqdn)
		if fzone == zone {
			values, verr := instLookupA(ctx, dns, zone, label)
			if verr == nil && (len(values) == 0 || values[0] != hzIPv4(s)) {
				findings = append(findings, finding{"dns-mismatch", s.Name, fmt.Sprintf("%s should be A %s, zone has %v", fqdn, hzIPv4(s), values)})
			}
		}
		if cp != nil && cpFindRow(rows, label, fzone, hzIPv4(s)) == nil {
			findings = append(findings, finding{"no-registry-row", s.Name, fqdn + " runs but the control plane has no row (standalone or drift?)"})
		}
	}

	// DNS: every A record should point at something we can account for.
	externalSeen := 0
	for _, rr := range rrsets {
		if rr.Type != hcloud.ZoneRRSetTypeA {
			continue
		}
		if external[rr.Name] {
			externalSeen++
			continue
		}
		for _, rec := range rr.Records {
			if _, okIP := byIP[rec.Value]; okIP {
				continue
			}
			who := rr.Name + "." + zone
			if cp != nil {
				if row := cpFindRow(rows, rr.Name, zone, rec.Value); row != nil {
					findings = append(findings, finding{"dns-row-no-server", who, fmt.Sprintf("A %s matches registry row %s but no managed server", rec.Value, row.Slug)})
					continue
				}
			}
			findings = append(findings, finding{"dns-unmatched", who, "A " + rec.Value + " matches no managed server (external service, or an orphan)"})
		}
	}

	// Registry rows: every row's host should be a managed server that agrees
	// on the identity.
	for i := range rows {
		row := &rows[i]
		if row.Host == "" {
			findings = append(findings, finding{"row-no-host", row.Slug, "registry row with no host (failed or unfinished provision)"})
			continue
		}
		s, okIP := byIP[row.Host]
		switch {
		case !okIP:
			findings = append(findings, finding{"row-stale-host", row.Slug, "row's host " + row.Host + " is no managed server (dead box or recycled IP)"})
		case s.Labels[cloud.FQDNLabelKey] != cloud.Fqdn(row.DNSLabel, zone):
			findings = append(findings, finding{"row-ip-conflict", row.Slug, fmt.Sprintf("row's host %s is owned by %s (%s) — recycled IP", row.Host, s.Name, s.Labels[cloud.FQDNLabelKey])})
		}
		if row.DeprovisionStatus == "failed" {
			findings = append(findings, finding{"failed-deprovision", row.Slug, "the last deprovision job failed — see the control plane console"})
		}
	}

	// Idle primary IPs bill without serving anything.
	pips, perr := hc.PrimaryIP.All(ctx)
	if perr == nil {
		for _, p := range pips {
			if p.AssigneeID == 0 {
				findings = append(findings, finding{"orphan-primary-ip", p.IP.String(), "unassigned primary IP (billing for nothing)"})
			}
		}
	}

	summary := map[string]any{
		"servers":  len(servers),
		"archives": len(archives),
		"findings": findings,
		"ok":       len(findings) == 0,
	}
	if externalSeen > 0 {
		summary["external_dns"] = externalSeen
	}
	if cp != nil {
		summary["registry_rows"] = len(rows)
	}
	if out.emitStructured(summary) {
		if len(findings) > 0 {
			return exitGeneric
		}
		return exitOK
	}
	out.outf("fleet: %d managed server(s), %d archive(s)%s", len(servers), len(archives), func() string {
		if cp != nil {
			return fmt.Sprintf(", %d registry row(s)", len(rows))
		}
		return " (registry not checked — no WORKER_TOKEN)"
	}())
	if len(findings) == 0 {
		out.outf("✓ audit clean — servers, DNS and registry are coherent")
		return exitOK
	}
	tbl := make([][]string, 0, len(findings))
	for _, f := range findings {
		tbl = append(tbl, []string{hzCell(f.Kind), hzCell(f.Who), hzCell(f.Detail)})
	}
	renderHzTable(out, []string{"FINDING", "WHO", "DETAIL"}, tbl)
	return exitGeneric
}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

func printHetznerInstanceHelp(out *writer) {
	const help = `bp cloud hetzner instance — fleet lifecycle: archive, decommission, resurrect, migrate.

An instance is server + DNS record + control-plane registry row, handled as ONE
unit. An archive is a Hetzner snapshot stamped with resurrection labels — the
box's database, media, secrets and TLS certs ride inside it.

USAGE
  bp cloud hetzner instance archive      <fqdn|server> [--stop]
  bp cloud hetzner instance archives     [<fqdn>]
  bp cloud hetzner instance decommission <fqdn|server> [--no-archive] [--direct] [--force] [--yes]
  bp cloud hetzner instance resurrect    <fqdn> [--image <id>] [--type <t>] [--location <l>]
                                         [--ssh-key <k>] [--no-health]
  bp cloud hetzner instance adopt        <fqdn|server> --team <team-id> [--admin-token <t>]
                                         [--name <n>] [--keep-old]
  bp cloud hetzner instance eject        <fqdn|slug|server> [--keep-old]
  bp cloud hetzner instance export       <fqdn|server|ip> [--out <f>] [--bucket <b>]
  bp cloud hetzner instance import       <file> --target <fqdn|server|ip> --yes
  bp cloud hetzner instance audit        [--external <label,…>]

CREDENTIALS
  compute    --token > HCLOUD_TOKEN > hcloud context (the fleet's project)
  dns        --dns-token > BARKPARK_DNS_HCLOUD_TOKEN > compute token
             (the zone may live in a different Hetzner project)
  registry   --worker-token > WORKER_TOKEN, --control-url > BARKPARK_CONTROL_URL
             (default https://barkpark.cloud); absent → registry steps skipped

VERBS
  archive       snapshot the box with resurrection labels; --stop quiesces the
                data writers first (application-consistent, brief API outage)
  decommission  archive (unless --no-archive), remove the registry row via the
                control plane's own deprovision queue (or --direct), tear down
                the box + A record, then VERIFY nothing survived — any residue
                is a non-zero exit. Also cleans residue of already-dead boxes.
                --yes skips the typed-name confirm; --force overrides the
                fqdn-label ownership check on the server delete.
  resurrect     newest archive (or --image) → new server → DNS → health gate on
                https://<fqdn>/api/schemas. Infra-level: the registry row is
                not recreated (use adopt for that).
  adopt         standalone → SaaS tenant: archive, boot a clone, repoint DNS,
                health-gate, register the row, destroy the old box (--keep-old
                keeps it). v1 keeps the fqdn (slug = the existing DNS label).
  eject         SaaS tenant → standalone: the mirror — clone-swap, then detach
                the registry row so the control plane no longer manages it.
  export        portable data archive (pg_dump + media + identity secrets) —
                restores onto ANY ssh-able Barkpark box, unlike snapshots
                which cannot leave their Hetzner project. --bucket streams to
                Object Storage instead of a local file.
  import        restore an export onto a target box: OVERWRITES its database
                and media (--yes required), keeps the target's host identity,
                replays migrations, health-gates on localhost.
  audit         cross-check servers ↔ DNS ↔ registry ↔ archives and report
                every orphan, mismatch, stale row and idle primary IP;
                non-zero exit when findings exist (a residue gate for CI).
                --external (or BARKPARK_AUDIT_EXTERNAL) names DNS labels that
                legitimately point outside the fleet — counted, not flagged.

EXAMPLE
  bp cloud hetzner instance decommission okey.barkpark.cloud
  bp cloud hetzner instance resurrect okey.barkpark.cloud
  bp cloud hetzner instance adopt guerrilla.barkpark.cloud --team <team-uuid>
  bp cloud hetzner instance export gyldendal.barkpark.cloud --out gyldendal.tar.gz
  bp cloud hetzner instance import gyldendal.tar.gz --target 203.0.113.7 --yes
  bp cloud hetzner instance audit --external @,www,api,mail,guerrilla -o json`
	out.outf("%s", help)
}
