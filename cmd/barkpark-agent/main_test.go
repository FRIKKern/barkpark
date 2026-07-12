package main

import "testing"

func TestAgentHealthGateOpts(t *testing.T) {
	got := agentHealthGateOpts("https://box.example.com", "")
	if !got.StubsOptional {
		t.Fatal("agent health gate must treat unwired agent/backup stubs as optional")
	}
	if got.PostgresProbeURL != "https://box.example.com/status.json" {
		t.Fatalf("PostgresProbeURL = %q, want public status DB probe", got.PostgresProbeURL)
	}
	if !got.RequireDatabaseStatusOperational {
		t.Fatal("agent health gate must require the public database status to be operational")
	}
	if got.Token != "" {
		t.Fatalf("Token = %q, want empty when no instance health token is configured", got.Token)
	}
}
