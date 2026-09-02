package runtime

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// --- a stateful fake Docker --------------------------------------------------
//
// The existing fakeRunner records calls and answers nothing, which is enough
// for "was docker run called". It cannot prove a RETENTION property: that
// needs an inventory which the executor's own calls mutate, so that N+3
// consecutive deploys can be asked whether the image count stopped growing.
// dockerBox is that inventory — a tiny in-process Docker with images,
// containers and the exact subcommand surface internal/runtime shells out to.
// No daemon, no root, no network.

type boxImage struct {
	ref  string
	size int64
}

type boxContainer struct {
	id      string
	name    string
	image   string
	state   string // "running" | "exited"
	port    int
	created time.Time
}

type dockerBox struct {
	t          *testing.T
	images     []boxImage
	containers []boxContainer
	clock      time.Time
	nextID     int
	imageSize  int64
	log        []string

	// refusePrune makes `docker image rm` fail, standing in for a daemon that
	// cannot remove an image right now.
	refusePrune bool
}

func newDockerBox(t *testing.T) *dockerBox {
	return &dockerBox{
		t:         t,
		clock:     time.Date(2026, 8, 1, 4, 0, 0, 0, time.UTC),
		imageSize: 1_153_000_000, // ~1.15 GB — 20.76 GB / 18 images on jarl
	}
}

func (b *dockerBox) tick() time.Time {
	b.clock = b.clock.Add(90 * time.Second)
	return b.clock
}

func (b *dockerBox) findImage(ref string) int {
	for i, im := range b.images {
		if im.ref == ref {
			return i
		}
	}
	return -1
}

func (b *dockerBox) findContainer(idOrName string) int {
	for i, c := range b.containers {
		if c.id == idOrName || c.name == idOrName {
			return i
		}
	}
	return -1
}

func (b *dockerBox) imageCount() int     { return len(b.images) }
func (b *dockerBox) containerCount() int { return len(b.containers) }

func (b *dockerBox) diskBytes() int64 {
	var n int64
	for _, im := range b.images {
		n += im.size
	}
	return n
}

// dockerImages renders the inventory the way `docker images` does, so a run
// can paste a real before/after table.
func (b *dockerBox) dockerImages() string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "%-32s %-12s %s\n", "REPOSITORY", "TAG", "SIZE")
	imgs := append([]boxImage(nil), b.images...)
	sort.Slice(imgs, func(i, j int) bool { return imgs[i].ref < imgs[j].ref })
	for _, im := range imgs {
		fmt.Fprintf(&sb, "%-32s %-12s %s\n", im.ref, "latest", humanBytes(im.size))
	}
	fmt.Fprintf(&sb, "TOTAL %d image(s), %s\n", len(imgs), humanBytes(b.diskBytes()))
	return sb.String()
}

var publishRe = regexp.MustCompile(`publish=(\d+)`)

func (b *dockerBox) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	b.log = append(b.log, name+" "+strings.Join(args, " "))

	// The drain runs through `sh -c "docker ps -q --filter publish=N | xargs
	// -r docker stop -t 5"`. Honour it as a real stop so the previous
	// generation actually becomes `exited` — a still-running container is one
	// the sweep must refuse to reap, so faking the drain away would make the
	// retention assertion vacuous.
	if name == "sh" && len(args) == 2 && args[0] == "-c" {
		m := publishRe.FindStringSubmatch(args[1])
		if m == nil {
			return nil
		}
		port, _ := strconv.Atoi(m[1])
		for i := range b.containers {
			if b.containers[i].port == port && b.containers[i].state == "running" {
				b.containers[i].state = "exited"
			}
		}
		return nil
	}

	if name == "caddy" {
		return nil
	}
	if name != "docker" {
		return nil
	}
	if len(args) == 0 {
		return fmt.Errorf("docker: no subcommand")
	}

	switch args[0] {
	case "load":
		// docker load -i <CacheDir>/<tag>.tar
		if len(args) < 3 || args[1] != "-i" {
			return fmt.Errorf("docker load: unexpected args %v", args)
		}
		base := args[2]
		if i := strings.LastIndex(base, "/"); i >= 0 {
			base = base[i+1:]
		}
		ref := strings.TrimSuffix(base, ".tar")
		if b.findImage(ref) < 0 {
			b.images = append(b.images, boxImage{ref: ref, size: b.imageSize})
		}
		return nil

	case "run":
		var cname string
		port := 0
		for i := 0; i < len(args); i++ {
			switch args[i] {
			case "--name":
				if i+1 < len(args) {
					cname = args[i+1]
				}
			case "-p":
				if i+1 < len(args) {
					parts := strings.Split(args[i+1], ":")
					if len(parts) == 3 {
						port, _ = strconv.Atoi(parts[1])
					}
				}
			}
		}
		ref := args[len(args)-1]
		if b.findImage(ref) < 0 {
			return fmt.Errorf("docker run: no such image %s", ref)
		}
		if b.findContainer(cname) >= 0 {
			return fmt.Errorf("docker run: name %s already in use", cname)
		}
		b.nextID++
		b.containers = append(b.containers, boxContainer{
			id:      fmt.Sprintf("c%08d", b.nextID),
			name:    cname,
			image:   ref,
			state:   "running",
			port:    port,
			created: b.tick(),
		})
		return nil

	case "rm":
		target := args[len(args)-1]
		i := b.findContainer(target)
		if i < 0 {
			return fmt.Errorf("docker rm: no such container %s", target)
		}
		b.containers = append(b.containers[:i], b.containers[i+1:]...)
		return nil

	case "ps":
		return b.ps(w, args[1:])

	case "image":
		if len(args) >= 2 && args[1] == "inspect" {
			ref := args[len(args)-1]
			i := b.findImage(ref)
			if i < 0 {
				return fmt.Errorf("docker image inspect: no such image %s", ref)
			}
			fmt.Fprintf(w, "%d\n", b.images[i].size)
			return nil
		}
		if len(args) >= 2 && args[1] == "rm" {
			if b.refusePrune {
				return fmt.Errorf("docker image rm: daemon refused")
			}
			ref := args[len(args)-1]
			i := b.findImage(ref)
			if i < 0 {
				return fmt.Errorf("docker image rm: no such image %s", ref)
			}
			// Real docker refuses to remove an image a container still
			// references. Modelling that is what makes "never remove the
			// image a kept container needs" a testable claim rather than an
			// assertion about our own bookkeeping.
			for _, c := range b.containers {
				if c.image == ref {
					return fmt.Errorf("docker image rm: conflict: image %s is in use by container %s", ref, c.name)
				}
			}
			b.images = append(b.images[:i], b.images[i+1:]...)
			return nil
		}
		return fmt.Errorf("docker image: unexpected args %v", args)

	case "builder":
		fmt.Fprintln(w, "Total reclaimed space: 0B")
		return nil
	}
	return nil
}

// ps answers `docker ps -q --filter publish=N` and the sweep's
// `-a --no-trunc --filter name=... --format ...`, newest-first like the real
// CLI.
func (b *dockerBox) ps(w io.Writer, args []string) error {
	all, quiet := false, false
	nameFilter, publishFilter, format := "", "", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-a":
			all = true
		case "-q":
			quiet = true
		case "--filter":
			if i+1 < len(args) {
				f := args[i+1]
				if v, ok := strings.CutPrefix(f, "name="); ok {
					nameFilter = v
				}
				if v, ok := strings.CutPrefix(f, "publish="); ok {
					publishFilter = v
				}
			}
		case "--format":
			if i+1 < len(args) {
				format = args[i+1]
			}
		}
	}

	rows := append([]boxContainer(nil), b.containers...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].created.After(rows[j].created) })

	for _, c := range rows {
		if !all && c.state != "running" {
			continue
		}
		// The real --filter name= is a loose SUBSTRING regex, not a prefix
		// match. Modelling it loosely is deliberate: it is exactly why
		// ownsContainer must re-check ownership in Go.
		if nameFilter != "" && !strings.Contains(c.name, nameFilter) {
			continue
		}
		if publishFilter != "" && strconv.Itoa(c.port) != publishFilter {
			continue
		}
		if quiet {
			fmt.Fprintln(w, c.id)
			continue
		}
		if format == sweepPSFormat {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n",
				c.id, c.name, c.image, c.state,
				c.created.Format(dockerCreatedAtLayout))
			continue
		}
		fmt.Fprintln(w, c.id)
	}
	return nil
}

// --- the deploy harness ------------------------------------------------------

// deployRig drives real RunOnce cycles against dockerBox. Each cycle gets its
// own live listener so the executor's REAL healthCheck answers on the REAL
// allocated port — the health gate is not stubbed out.
type deployRig struct {
	t    *testing.T
	box  *dockerBox
	exec *Executor
	cp   *scriptedCP
	logs []string
}

type listenerPorts struct {
	ports []int
	i     int
}

func (l *listenerPorts) Allocate(map[int]bool) (int, error) {
	if l.i >= len(l.ports) {
		return 0, fmt.Errorf("out of test listeners")
	}
	p := l.ports[l.i]
	l.i++
	return p, nil
}

func newDeployRig(t *testing.T, deploys int, retain int) *deployRig {
	t.Helper()

	cp := newCP(t)
	for i := 1; i <= deploys; i++ {
		cp.pending = append(cp.pending, claimReply{
			deployment: Deployment{
				ID:       fmt.Sprintf("%08d-1111-2222-3333-444444444444", i),
				SiteID:   "s0000001-0000-0000-0000-000000000000",
				Status:   "pushing",
				ImageTag: fmt.Sprintf("site-s0000001-%08d", i),
				Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
			},
			epoch: i,
		})
	}
	srv := httptest.NewServer(cp.handler())
	t.Cleanup(srv.Close)

	// One real listener per deploy — a distinct port per generation, exactly
	// like a real blue/green swap, so the drain has a previous port to stop.
	var ports []int
	for i := 0; i < deploys; i++ {
		c := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		t.Cleanup(c.Close)
		ports = append(ports, mustPort(t, c.URL))
	}

	box := newDockerBox(t)
	rig := &deployRig{t: t, box: box, cp: cp}
	rig.exec = &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        box,
		FS:            newMapFS(),
		Ports:         &listenerPorts{ports: ports},
		RetainImages:  retain,
		HealthTimeout: 5 * time.Second,
		Logger: func(format string, args ...any) {
			rig.logs = append(rig.logs, fmt.Sprintf(format, args...))
		},
	}
	return rig
}

// deploy runs ONE full cycle the way the cmd wrapper does: rebuild state from
// the on-disk Caddyfile, then RunOnce.
func (r *deployRig) deploy() bool {
	r.t.Helper()
	ctx := context.Background()
	state, err := r.exec.StateFromDisk(ctx)
	if err != nil {
		r.t.Fatalf("StateFromDisk: %v", err)
	}
	had, err := r.exec.RunOnce(ctx, state)
	if err != nil {
		r.t.Fatalf("RunOnce: %v", err)
	}
	return had
}

func (r *deployRig) logText() string { return strings.Join(r.logs, "\n") }

// --- the retention proof -----------------------------------------------------

// TestRetention_ConsecutiveDeploys_ImageCountSettlesAtTheWindow is the row's
// core claim: more than N consecutive deploys must stop growing the image
// store and settle at the retention window.
//
// MUTATION PROOF: comment out the e.sweepSiteImages(...) call in RunOnce and
// this test reds with "unbounded growth" naming the exact counts (6 images
// after 6 deploys instead of 3).
func TestRetention_ConsecutiveDeploys_ImageCountSettlesAtTheWindow(t *testing.T) {
	const keep = 3
	const deploys = keep + 3 // N+3 — past the window, twice over

	rig := newDeployRig(t, deploys, keep)

	t.Logf("docker images BEFORE (deploy 0):\n%s", rig.box.dockerImages())

	var imageCounts, containerCounts []int
	for i := 1; i <= deploys; i++ {
		if !rig.deploy() {
			t.Fatalf("deploy %d: nothing claimed", i)
		}
		imageCounts = append(imageCounts, rig.box.imageCount())
		containerCounts = append(containerCounts, rig.box.containerCount())
		t.Logf("after deploy %d: %d image(s), %d container(s), %s on disk",
			i, rig.box.imageCount(), rig.box.containerCount(), humanBytes(rig.box.diskBytes()))
	}

	t.Logf("docker images AFTER (deploy %d):\n%s", deploys, rig.box.dockerImages())

	want := []int{1, 2, 3, 3, 3, 3}
	if fmt.Sprint(imageCounts) != fmt.Sprint(want) {
		t.Fatalf("UNBOUNDED GROWTH: image count per deploy = %v, want %v "+
			"(the store must settle at the %d-generation window, not grow one image per deploy). "+
			"Final: %d images / %s on disk, want %d images.",
			imageCounts, want, keep, rig.box.imageCount(), humanBytes(rig.box.diskBytes()), keep)
	}
	if fmt.Sprint(containerCounts) != fmt.Sprint(want) {
		t.Fatalf("UNBOUNDED GROWTH: container count per deploy = %v, want %v "+
			"(a never-removed stopped container pins its image against every prune)",
			containerCounts, want)
	}

	// The window is 1 live + keep-1 rollback targets, and the live one is the
	// newest deployment.
	running, exited := 0, 0
	for _, c := range rig.box.containers {
		if c.state == "running" {
			running++
		} else {
			exited++
		}
	}
	if running != 1 {
		t.Errorf("want exactly 1 running (live) container, got %d", running)
	}
	if exited != keep-1 {
		t.Errorf("want %d stopped rollback container(s) (N-1), got %d", keep-1, exited)
	}

	liveTag := fmt.Sprintf("site-s0000001-%08d", deploys)
	if rig.box.findImage(liveTag) < 0 {
		t.Fatalf("the image that is actually SERVING (%s) was reaped; images: %v", liveTag, rig.box.images)
	}
	for i := 1; i <= deploys-keep; i++ {
		old := fmt.Sprintf("site-s0000001-%08d", i)
		if rig.box.findImage(old) >= 0 {
			t.Errorf("image %s is %d generations old and still on disk", old, deploys-i)
		}
	}

	if !strings.Contains(rig.logText(), "reclaimed") {
		t.Errorf("the sweep never logged what it removed with sizes; log:\n%s", rig.logText())
	}
	t.Logf("retention log:\n%s", rig.logText())
}

// TestRetention_LogsWhatItRemovedWithSizes proves the operator-visible half:
// the journal names the containers, the images and the bytes reclaimed.
func TestRetention_LogsWhatItRemovedWithSizes(t *testing.T) {
	rig := newDeployRig(t, 3, 2)
	for i := 1; i <= 3; i++ {
		rig.deploy()
	}
	log := rig.logText()
	for _, want := range []string{
		"site-shop-00000001",     // the container it removed, by name
		"site-s0000001-00000001", // the image it removed, by ref
		"GB)",                    // the per-image size
		"reclaimed 1.2 GB",       // the total
		"1 live + 1 rollback",    // the window it swept to
	} {
		if !strings.Contains(log, want) {
			t.Errorf("retention log does not mention %q; log:\n%s", want, log)
		}
	}
	t.Logf("retention log:\n%s", log)
}

// TestRetention_FailedCutoverKeepsThePreviousImage is the safety half: a
// deploy that does NOT cut over must reap nothing, so its rollback target
// survives. keep=1 makes the sweep maximally aggressive, so a sweep that ran
// at the wrong time would be unmissable.
func TestRetention_FailedCutoverKeepsThePreviousImage(t *testing.T) {
	rig := newDeployRig(t, 3, 1)

	rig.deploy() // generation 1 goes live
	rig.deploy() // generation 2 goes live; generation 1 is reaped

	if got := rig.box.imageCount(); got != 1 {
		t.Fatalf("precondition: want 1 image after two proven cutovers at keep=1, got %d", got)
	}
	survivor := "site-s0000001-00000002"
	if rig.box.findImage(survivor) < 0 {
		t.Fatalf("precondition: the live image %s is gone", survivor)
	}

	// Third deploy: Caddy refuses to reload, so the cutover never happens.
	// Snapshot the journal first — the two PROVEN cutovers above legitimately
	// swept, and scanning their lines would make the "did not sweep" assertion
	// fire on the wrong deploy.
	logsBefore := len(rig.logs)
	rig.exec.Runner = &failingCaddyBox{dockerBox: rig.box}
	rig.deploy()

	if last := rig.cp.lastTransition(t); last["status"] != "failed" {
		t.Fatalf("want the third deploy to fail its transition, got %v", last["status"])
	}
	if rig.box.findImage(survivor) < 0 {
		t.Fatalf("A FAILED CUTOVER REAPED THE ROLLBACK TARGET: image %s is gone. "+
			"images: %v", survivor, rig.box.images)
	}
	if i := rig.box.findContainer("site-shop-00000002"); i < 0 {
		t.Fatalf("A FAILED CUTOVER REAPED THE ROLLBACK CONTAINER site-shop-00000002; containers: %v",
			rig.box.containers)
	} else if rig.box.containers[i].state != "running" {
		t.Errorf("the rollback container should still be serving, state=%s", rig.box.containers[i].state)
	}
	for _, line := range rig.logs[logsBefore:] {
		if strings.Contains(line, "swept to a") || strings.Contains(line, "nothing to reap") {
			t.Errorf("the sweep RAN on a failed cutover: %s", line)
		}
	}
}

// failingCaddyBox is dockerBox with a broken `caddy reload`.
type failingCaddyBox struct{ *dockerBox }

func (f *failingCaddyBox) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	if name == "caddy" {
		return fmt.Errorf("exit status 1: caddy not running")
	}
	return f.dockerBox.Run(ctx, w, name, args...)
}

// TestRetention_DisabledKeepsEverything pins the escape hatch: -1 restores the
// historical never-delete behaviour, so an operator can turn the sweep off
// without editing code.
func TestRetention_DisabledKeepsEverything(t *testing.T) {
	rig := newDeployRig(t, 5, RetainImagesUnlimited)
	for i := 1; i <= 5; i++ {
		rig.deploy()
	}
	if got := rig.box.imageCount(); got != 5 {
		t.Fatalf("retain=-1 must keep every image; got %d of 5", got)
	}
	if !strings.Contains(rig.logText(), "disabled") {
		t.Errorf("a disabled sweep must say so in the journal; log:\n%s", rig.logText())
	}
}

// TestRetention_ImageRmFailureLeavesTheDeployLive proves the best-effort
// contract: a daemon that refuses `docker image rm` must not fail a deployment
// that is already serving.
func TestRetention_ImageRmFailureLeavesTheDeployLive(t *testing.T) {
	rig := newDeployRig(t, 3, 1)
	rig.box.refusePrune = true
	for i := 1; i <= 3; i++ {
		if !rig.deploy() {
			t.Fatalf("deploy %d: nothing claimed", i)
		}
	}
	last := rig.cp.lastTransition(t)
	if last["status"] != "live" {
		t.Fatalf("a refused image rm failed the deploy: status=%v", last["status"])
	}
	if !strings.Contains(rig.logText(), "docker image rm") {
		t.Errorf("the refusal was swallowed silently; log:\n%s", rig.logText())
	}
}

// --- pure-rule tests ---------------------------------------------------------

func TestPlanRetention(t *testing.T) {
	at := func(min int) time.Time {
		return time.Date(2026, 8, 1, 4, min, 0, 0, time.UTC)
	}
	row := func(name string, min int, state string) siteContainer {
		return siteContainer{
			id: "c-" + name, name: name, image: "img-" + name,
			state: state, created: at(min), hasTime: true,
		}
	}

	t.Run("keeps the newest N and reaps the rest", func(t *testing.T) {
		rows := []siteContainer{
			row("site-shop-04", 40, "running"),
			row("site-shop-03", 30, "exited"),
			row("site-shop-02", 20, "exited"),
			row("site-shop-01", 10, "exited"),
		}
		kept, doomed := planRetention(rows, "site-shop-04", 2)
		if got := names(kept); fmt.Sprint(got) != "[site-shop-04 site-shop-03]" {
			t.Errorf("kept = %v", got)
		}
		if got := names(doomed); fmt.Sprint(got) != "[site-shop-02 site-shop-01]" {
			t.Errorf("doomed = %v", got)
		}
	})

	t.Run("the live container is kept even when its clock looks oldest", func(t *testing.T) {
		rows := []siteContainer{
			row("site-shop-09", 90, "exited"),
			row("site-shop-01", 10, "running"), // the one just deployed
		}
		kept, doomed := planRetention(rows, "site-shop-01", 1)
		if got := names(kept); fmt.Sprint(got) != "[site-shop-01]" {
			t.Errorf("kept = %v, want the live container first regardless of CreatedAt", got)
		}
		if got := names(doomed); fmt.Sprint(got) != "[site-shop-09]" {
			t.Errorf("doomed = %v", got)
		}
	})

	t.Run("a running container out of the window is never a victim", func(t *testing.T) {
		rows := []siteContainer{
			row("site-shop-03", 30, "running"),
			row("site-shop-02", 20, "running"), // still serving something
			row("site-shop-01", 10, "exited"),
		}
		kept, doomed := planRetention(rows, "site-shop-03", 1)
		if got := names(doomed); fmt.Sprint(got) != "[site-shop-01]" {
			t.Errorf("doomed = %v — a RUNNING container must never be reaped", got)
		}
		if len(kept) != 2 {
			t.Errorf("kept = %v, want the live one plus the still-running one", names(kept))
		}
	})

	t.Run("keep<=0 disables the sweep", func(t *testing.T) {
		rows := []siteContainer{row("site-shop-02", 20, "running"), row("site-shop-01", 10, "exited")}
		if _, doomed := planRetention(rows, "site-shop-02", RetainImagesUnlimited); doomed != nil {
			t.Errorf("retain=-1 reaped %v", names(doomed))
		}
	})

	t.Run("unparseable stamps fall back to docker's newest-first order", func(t *testing.T) {
		rows := []siteContainer{
			{id: "a", name: "site-shop-03", state: "running"},
			{id: "b", name: "site-shop-02", state: "exited"},
			{id: "c", name: "site-shop-01", state: "exited"},
		}
		_, doomed := planRetention(rows, "site-shop-03", 2)
		if got := names(doomed); fmt.Sprint(got) != "[site-shop-01]" {
			t.Errorf("doomed = %v, want the last row of docker's own ordering", got)
		}
	})
}

func names(rows []siteContainer) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.name)
	}
	return out
}

// TestOwnsContainer_LongerSlugIsNotMine is the sharp edge: `docker ps --filter
// name=site-jarl-` also returns site-jarl-website-*, and reaping those would
// delete a DIFFERENT live site's rollback container.
func TestOwnsContainer_LongerSlugIsNotMine(t *testing.T) {
	live := []string{"jarl-website", "shop"}
	cases := []struct {
		name, slug string
		want       bool
	}{
		{"site-jarl-2f92055a", "jarl", true},
		{"site-jarl-website-2f92055a", "jarl", false},
		{"site-jarl-website-2f92055a", "jarl-website", true},
		{"site-shop-abc", "jarl", false},
		{"site-jarl-", "jarl", false},
		{"site-jarl", "jarl", false},
		{"other-jarl-abc", "jarl", false},
	}
	for _, c := range cases {
		if got := ownsContainer(c.name, c.slug, live); got != c.want {
			t.Errorf("ownsContainer(%q, %q) = %v, want %v", c.name, c.slug, got, c.want)
		}
	}
}

func TestParsePSRows(t *testing.T) {
	out := "c1\tsite-shop-01\tsite-s1-01\trunning\t2026-08-01 04:12:33 +0200 CEST\n" +
		"\n" +
		"garbage-line\n" +
		"c2\tsite-shop-02\tsite-s1-02\texited\tnot-a-time\n"
	rows := parsePSRows(out)
	if len(rows) != 2 {
		t.Fatalf("want 2 rows (the blank and the malformed line skipped), got %d: %+v", len(rows), rows)
	}
	if !rows[0].hasTime || rows[0].created.Year() != 2026 {
		t.Errorf("row 0 CreatedAt did not parse: %+v", rows[0])
	}
	if rows[1].hasTime {
		t.Errorf("row 1 should have no usable stamp: %+v", rows[1])
	}
	if !rows[0].running() || rows[1].running() {
		t.Errorf("state parsing wrong: %+v", rows)
	}
}

func TestRetainImagesAndBuildCacheDefaults(t *testing.T) {
	if got := (&Executor{}).retainImages(); got != DefaultRetainImages {
		t.Errorf("unset RetainImages = %d, want the default %d", got, DefaultRetainImages)
	}
	if got := (&Executor{RetainImages: 7}).retainImages(); got != 7 {
		t.Errorf("RetainImages=7 resolved to %d", got)
	}
	if got := (&Executor{RetainImages: RetainImagesUnlimited}).retainImages(); got >= 0 {
		t.Errorf("RetainImagesUnlimited resolved to %d, want a disabling value", got)
	}
	if got := (&Executor{}).buildCacheKeep(); got != DefaultBuildCacheKeep {
		t.Errorf("unset BuildCacheKeep = %q", got)
	}
	if got := (&Executor{BuildCacheKeep: "OFF"}).buildCacheKeep(); got != "" {
		t.Errorf("BuildCacheKeep=OFF = %q, want disabled", got)
	}
}

func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{
		0:              "0 B",
		999:            "999 B",
		20_760_000_000: "20.8 GB",
		1_153_000_000:  "1.2 GB",
	}
	for in, want := range cases {
		if got := humanBytes(in); got != want {
			t.Errorf("humanBytes(%d) = %q, want %q", in, got, want)
		}
	}
}

// lastTransition returns the most recent transition body the scripted control
// plane received. Defined here rather than in runtime_test.go so this file
// carries its own accessors.
func (s *scriptedCP) lastTransition(t *testing.T) map[string]any {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.transitions) == 0 {
		t.Fatalf("no transitions recorded")
	}
	return s.transitions[len(s.transitions)-1]
}

// --- the real box ------------------------------------------------------------

// jarlBoxPS is VERBATIM output from the box the incident was filed against,
// captured read-only on 2026-09-02:
//
//	ssh root@91.98.139.58 docker ps -a --no-trunc \
//	  --filter name=site-jarl-website- --format '<sweepPSFormat>'
//
// Alongside it, `docker system df` reported: Images 8, ACTIVE 8, 14.13 GB —
// every image referenced by a container, so `docker image prune -a` on that
// box reclaims ZERO. That is the incident's mechanism in one line: the sweep
// this file adds is not "prune unreferenced images", it is "stop referencing
// images older than the rollback window".
const jarlBoxPS = "63036f651e8bc20ff9c2d962d24dc1b881d503e793115c7bac15105bab6118d0\tsite-jarl-website-4b8b886b\tsite-b376168d-4b8b886b\trunning\t2026-08-03 12:54:14 +0000 UTC\n" +
	"fdee902a405ce1d3b998fd94500c7aafdca1601b9de331c44c2181d125e737ec\tsite-jarl-website-96790434\tsite-b376168d-96790434\texited\t2026-08-01 22:27:57 +0000 UTC\n" +
	"142a558266eb8c6d5ac84256f1078ddc98e06b43eab045271f1f7a6b33e0bacb\tsite-jarl-website-9e62c536\tsite-b376168d-9e62c536\texited\t2026-08-01 14:02:57 +0000 UTC\n" +
	"8fd318a923462a981e8281ecffd7feb0920e6a30ca9ef72d467216f59b6a25e2\tsite-jarl-website-1d9f4e11\tsite-b376168d-1d9f4e11\texited\t2026-08-01 12:47:35 +0000 UTC\n" +
	"8876f60d79a8e2aad2c93a9b62ff45b25ddbeeb1b42c304373a8296a1f6f8b7d\tsite-jarl-website-a81f9e97\tsite-b376168d-a81f9e97\texited\t2026-08-01 10:11:20 +0000 UTC\n" +
	"fb8125b4e996629188beca063a4924c91a0ec76d5bfd08f50b4c4c99bfa26cca\tsite-jarl-website-ffa43110\tsite-b376168d-ffa43110\texited\t2026-08-01 02:29:30 +0000 UTC\n" +
	"8c52afedca782d33ef3e6d6627fcd83064c14e68db3d2b47853deea925947c84\tsite-jarl-website-b348c0a4\tsite-b376168d-b348c0a4\texited\t2026-08-01 00:54:54 +0000 UTC\n" +
	"d5ae3766de834be66f659e99a897cf95497cafe94eefa407bdab780c13c82025\tsite-jarl-website-2f92055a\tsite-b376168d-2f92055a\tcreated\t2026-07-30 18:56:13 +0000 UTC\n"

// jarlBoxImageSize is the per-image DISK USAGE column from that box's
// `docker images`, in bytes. Layers are shared between these builds, so the
// SUM over victims is an upper bound on what the daemon actually frees —
// `docker system df` dedupes the same 8 images to 14.13 GB, not 16.00 GB.
var jarlBoxImageSize = map[string]int64{
	"site-b376168d-4b8b886b": 2_050_000_000,
	"site-b376168d-96790434": 2_030_000_000,
	"site-b376168d-9e62c536": 2_030_000_000,
	"site-b376168d-1d9f4e11": 2_030_000_000,
	"site-b376168d-a81f9e97": 2_030_000_000,
	"site-b376168d-ffa43110": 2_030_000_000,
	"site-b376168d-b348c0a4": 2_030_000_000,
	"site-b376168d-2f92055a": 1_770_000_000,
}

// TestRetention_JarlBoxInventory runs the SHIPPED rule over the real box's
// real inventory, so the "after" figure in the PR is computed by the code
// under review rather than by hand. Nothing here touches a box.
func TestRetention_JarlBoxInventory(t *testing.T) {
	var mine []siteContainer
	for _, r := range parsePSRows(jarlBoxPS) {
		if ownsContainer(r.name, "jarl-website", nil) {
			mine = append(mine, r)
		}
	}
	if len(mine) != 8 {
		t.Fatalf("fixture: want 8 containers, parsed %d", len(mine))
	}

	kept, doomed := planRetention(mine, "site-jarl-website-4b8b886b", DefaultRetainImages)

	var before, freed int64
	for _, r := range mine {
		before += jarlBoxImageSize[r.image]
	}
	protected := map[string]bool{}
	for _, k := range kept {
		protected[k.image] = true
	}
	var victims []string
	for _, d := range doomed {
		if protected[d.image] {
			continue
		}
		victims = append(victims, d.name)
		freed += jarlBoxImageSize[d.image]
	}

	t.Logf("jarl box (91.98.139.58) BEFORE: %d images / %s (docker system df: 14.13 GB deduped, 8 of 8 ACTIVE)",
		len(mine), humanBytes(before))
	t.Logf("keep=%d -> KEPT   : %v", DefaultRetainImages, names(kept))
	t.Logf("keep=%d -> REAPED : %v", DefaultRetainImages, victims)
	t.Logf("jarl box computed AFTER: %d images / %s — reclaims %s (upper bound; shared layers)",
		len(kept), humanBytes(before-freed), humanBytes(freed))

	wantKept := "[site-jarl-website-4b8b886b site-jarl-website-96790434 site-jarl-website-9e62c536]"
	if got := fmt.Sprint(names(kept)); got != wantKept {
		t.Errorf("kept = %s, want %s (the live one plus the two newest rollback targets)", got, wantKept)
	}
	if len(victims) != 5 {
		t.Errorf("want 5 out-of-window generations reaped, got %d: %v", len(victims), victims)
	}
	// The container that is actually SERVING jarl.no must never be a victim.
	for _, v := range victims {
		if v == "site-jarl-website-4b8b886b" {
			t.Fatalf("the LIVE container would be reaped")
		}
	}
	// The `created`-but-never-started 2f92055a squatter (the exit-125 name
	// collision recorded in executeDeploy) is 8 generations old and is exactly
	// the kind of debris this sweep should clear.
	if !strings.Contains(fmt.Sprint(victims), "2f92055a") {
		t.Errorf("the stale `created` container was not reaped: %v", victims)
	}
}
