package provisioner

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// launch_host_feed_test.go — every Hetzner launch says, on its step feed and
// console, whether it took a warm server or creates a new one, and why
// (task-5d99ad9ae8d780f1). It drives ProvisionWith end to end and reads the
// create/progress details the step reporter received.
//
// The expected wording is written out literally on purpose. This file uses no
// symbol the fix added, so it compiles against the code before the fix and
// fails there: on 2026-11-19 a launch with WARM_POOL_SIZE=0 said nothing.

const (
	testWarmPrefix = "Warm server "
	testColdPrefix = "No warm server: "
	testColdSuffix = " — creating a new server"
)

// hostCaptions returns, in order, every create/progress detail that is a
// warm-or-cold line.
func hostCaptions(rec *detailRec) []string {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	var out []string
	for _, e := range rec.entries {
		if e.step == "create" && e.status == "progress" &&
			(strings.HasPrefix(e.detail, testWarmPrefix) || strings.HasPrefix(e.detail, testColdPrefix)) {
			out = append(out, e.detail)
		}
	}
	return out
}

// firstIndex returns the position of the first entry matching step/status and,
// when detail is non-empty, that exact detail. -1 when none.
func firstIndex(rec *detailRec, step, status, detail string) int {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	for i, e := range rec.entries {
		if e.step == step && e.status == status && (detail == "" || e.detail == detail) {
			return i
		}
	}
	return -1
}

func TestProvisionWith_NarratesWarmOrCold(t *testing.T) {
	type setup struct {
		seams Seams
		job   JobSpec
		// want is the LAST warm-or-cold caption; wantPrefix replaces it when the
		// tail holds an error text the test does not pin.
		want, wantPrefix string
		// earlier is a caption that must come before want (the warm line a failed
		// assign is followed by).
		earlier string
	}
	cases := []struct {
		name  string
		build func(t *testing.T, ctx context.Context) setup
	}{
		{"pool off (WARM_POOL_SIZE=0)", func(t *testing.T, _ context.Context) setup {
			seams, _, _, _ := fakeSeams(t)
			return setup{seams: seams, job: acmeJob(),
				want: "No warm server: warm pool is off on this worker (WARM_POOL_SIZE=0) — creating a new server"}
		}},
		{"pool on but empty", func(t *testing.T, _ context.Context) setup {
			seams, _, _, _ := fakeSeams(t)
			seams.WarmPoolSize = 2
			seams.WarmClient = &fakeWarmClient{}
			return setup{seams: seams, job: acmeJob(),
				want: "No warm server: no warm server ready — creating a new server"}
		}},
		{"claim error", func(t *testing.T, _ context.Context) setup {
			seams, _, _, _ := fakeSeams(t)
			seams.WarmPoolSize = 2
			seams.WarmClient = &fakeWarmClient{claimErr: errors.New("control plane unreachable")}
			return setup{seams: seams, job: acmeJob(),
				want: "No warm server: warm claim failed: control plane unreachable — creating a new server"}
		}},
		{"pin mismatch", func(t *testing.T, ctx context.Context) setup {
			seams, prov, _, _ := fakeSeams(t)
			wc := &fakeWarmClient{}
			seedWarmBox(t, ctx, prov, wc)
			seams.WarmPoolSize = 2
			seams.WarmClient = wc
			seams.WarmRefill = func(context.Context) {}
			job := JobSpec{JobID: "job-pin", Name: "Acme Co", Slug: "acme", Region: "fsn1", ServerType: "cx32"}
			return setup{seams: seams, job: job,
				want: "No warm server: this launch pins region fsn1 / type cx32, the pool is nbg1/cx23 — creating a new server"}
		}},
		{"warm server fails to assign", func(t *testing.T, ctx context.Context) setup {
			seams, prov, _, runner := fakeSeams(t)
			wc := &fakeWarmClient{}
			box := seedWarmBox(t, ctx, prov, wc)
			seams.RunnerFor = func(host string) cloud.StepRunner {
				if host == box.IP {
					return &recordingRunner{failOn: "migrate"}
				}
				return runner
			}
			seams.WarmPoolSize = 1
			seams.WarmClient = wc
			seams.WarmRefill = func(context.Context) {}
			return setup{seams: seams, job: acmeJob(),
				earlier:    "Warm server " + box.Name + " assigned",
				wantPrefix: "No warm server: warm server " + box.Name + " failed to assign: "}
		}},
		{"warm server assigned", func(t *testing.T, ctx context.Context) setup {
			seams, prov, _, _ := fakeSeams(t)
			wc := &fakeWarmClient{}
			box := seedWarmBox(t, ctx, prov, wc)
			seams.WarmPoolSize = 1
			seams.WarmClient = wc
			seams.WarmRefill = func(context.Context) {}
			return setup{seams: seams, job: acmeJob(), want: "Warm server " + box.Name + " assigned"}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// A fixed pool base, so the pin case differs and the others match.
			t.Setenv("BARKPARK_SERVER_LOCATION", "nbg1")
			t.Setenv("BARKPARK_SERVER_TYPE", "cx23")
			ctx := context.Background()
			s := tc.build(t, ctx)
			rec := &detailRec{}
			s.seams.StepReporter = rec.Report

			if _, _, _, _, err := ProvisionWith(ctx, s.seams, s.job); err != nil {
				t.Fatalf("ProvisionWith: %v", err)
			}

			got := hostCaptions(rec)
			if len(got) == 0 {
				t.Fatalf("no warm-or-cold create/progress line was reported; steps: %v", rec.all())
			}
			last := got[len(got)-1]
			switch {
			case s.want != "" && last != s.want:
				t.Errorf("last warm-or-cold line = %q, want %q", last, s.want)
			case s.wantPrefix != "" && (!strings.HasPrefix(last, s.wantPrefix) || !strings.HasSuffix(last, testColdSuffix)):
				t.Errorf("last warm-or-cold line = %q, want %q…%q", last, s.wantPrefix, testColdSuffix)
			}
			if s.earlier != "" && (len(got) < 2 || got[len(got)-2] != s.earlier) {
				t.Errorf("warm-or-cold lines = %q, want %q before the last one", got, s.earlier)
			}
			// The first line lands before the first create starts.
			first := firstIndex(rec, "create", "progress", got[0])
			if started := firstIndex(rec, "create", "started", ""); started < 0 || first > started {
				t.Errorf("warm-or-cold line at %d, first create/started at %d: the line must come first", first, started)
			}
		})
	}
}

// A non-Hetzner launch has its warm pool forced off on purpose, so it says
// nothing about warm servers (the pool-off line would blame WARM_POOL_SIZE,
// which is not why).
func TestProvisionWith_AzureSaysNothingAboutWarmServers(t *testing.T) {
	seams, hetznerProv, _, _ := fakeSeams(t)
	ctx := context.Background()
	azureProv := cloud.NewFakeProvider()
	cloud.Register(cloud.ProviderAzure, func(map[string]string) (cloud.CloudProvider, error) {
		return azureProv, nil
	})
	wc := &fakeWarmClient{}
	seedWarmBox(t, ctx, hetznerProv, wc)
	seams.WarmPoolSize = 5
	seams.WarmClient = wc
	rec := &detailRec{}
	seams.StepReporter = rec.Report
	t.Setenv(envAzureSSHPubKey, "ssh-ed25519 AAAAtest azure@barkpark")

	job := JobSpec{JobID: "job-az", Name: "Acme Co", Slug: "acme", Region: "eastus",
		ServerType: "Standard_B1s", Kind: cloud.ProviderAzure, Credentials: azureCreds()}
	if _, _, _, _, err := ProvisionWith(ctx, seams, job); err != nil {
		t.Fatalf("ProvisionWith (azure): %v", err)
	}
	if got := hostCaptions(rec); len(got) != 0 {
		t.Errorf("an azure launch reported warm-or-cold lines %q, want none", got)
	}
	if firstIndex(rec, "create", "started", "") < 0 {
		t.Fatalf("the azure launch never reported create/started; steps: %v", rec.all())
	}
}
