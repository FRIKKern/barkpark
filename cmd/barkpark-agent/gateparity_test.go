package main

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// The two health gates that run against a live instance — the warm pool's
// go-live gate and the on-box agent's per-beat gate — must agree on what an
// unwired optional stub MEANS. They did not agree once: go-live passed
// HealthGate{StubsOptional: true} while the agent passed a zero-value struct,
// so the same box was READY to go live and "down" on its very next beat, and
// every online instance in the fleet read as degraded
// (azh-agent-healthgate-down-finding).
//
// Nothing in the type system connects these two call sites, so the agreement is
// pinned here. This is the divergence-detector the row asked for.
func TestAgentAndGoLiveGatesAgreeOnStubSemantics(t *testing.T) {
	goLive := cloud.GoLiveHealthGateOpts()
	onBox := agentHealthGateOpts("https://box.example.com", "tok")

	if goLive.StubsOptional != onBox.StubsOptional {
		t.Fatalf("stub optionality diverges: go-live=%v, agent=%v — the same box would be READY to launch and down on its next beat",
			goLive.StubsOptional, onBox.StubsOptional)
	}
	if !onBox.StubsOptional {
		t.Fatal("both gates must treat the unwired cloud-9/10 stubs as optional; a fail-closed stub marks every healthy box down")
	}

	// Neither path wires the stub URLs yet, so both must ABSTAIN on them rather
	// than vote. If a future change wires one side only, this catches it: the
	// side with a URL would probe and the other would skip, and the two would
	// disagree about a box again.
	if goLive.AgentStatusURL != onBox.AgentStatusURL || goLive.BackupStatusURL != onBox.BackupStatusURL {
		t.Errorf("stub probe URLs diverge: go-live=(%q,%q) agent=(%q,%q) — wire both or neither",
			goLive.AgentStatusURL, goLive.BackupStatusURL, onBox.AgentStatusURL, onBox.BackupStatusURL)
	}
}

// The agent's Postgres probe must target an endpoint the agent is ENTITLED to
// read. It once derived a scoped /v1/data/query URL and hit it with the agent's
// own report token, which lacks data-read scope: a guaranteed 403 that the gate
// reported as a database failure on every single beat. /status.json is served
// by the public :api pipeline, so no credential can make it 403.
func TestAgentPostgresProbeTargetsAnEndpointItMayRead(t *testing.T) {
	opts := agentHealthGateOpts("https://box.example.com", "tok")
	if opts.PostgresProbeURL != "https://box.example.com/status.json" {
		t.Fatalf("PostgresProbeURL = %q, want the public /status.json — a scoped data-query URL 403s with the agent's token",
			opts.PostgresProbeURL)
	}
	if !opts.RequireDatabaseStatusOperational {
		t.Fatal("reading /status.json without requiring database=operational would pass on a box whose DB is down")
	}
}
