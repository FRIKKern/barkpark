package cli

import (
	"encoding/json"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

func cycleOpenCorrectionCommand() manifest.Command {
	return manifest.Command{
		ID:       "cycle.open",
		Noun:     "cycle",
		Verb:     "open",
		HTTP:     manifest.HTTP{Method: "POST", PathTemplate: "/v1/cycles/:epic_id/:wave_id/open"},
		AuthTier: "write",
		Args: []manifest.Arg{
			{Name: "epic_id", Required: true, Type: "string"},
			{Name: "wave_id", Required: true, Type: "string"},
			{Name: "profile", Required: false, Type: "string"},
			{Name: "inventory_json", Required: false, Type: "string"},
			{Name: "scale_contract_json", Required: false, Type: "string"},
		},
		Flags: []manifest.Flag{
			{Name: "experiment_contract_json", Type: "string"},
			{Name: "correction_of_json", Type: "string"},
			{Name: "correction_of_digest", Type: "string"},
			{Name: "release_gate_receipt_json", Type: "string"},
		},
		Writes: true,
	}
}

func TestCycleOpenCorrectionNeedsOnlyWaveIdentity(t *testing.T) {
	cmd := cycleOpenCorrectionCommand()
	correction := `{"version":"correction_of-v1","prior_wave_id":"wave-1"}`

	pos, flags, err := splitArgs(cmd, []string{
		"epic-1", "wave-2",
		"--correction_of_json", correction,
		"--correction_of_digest", "sha256:abc",
	})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		t.Fatalf("bindArgs rejected correction mode without standard inputs: %v", err)
	}
	if len(args) != 2 || args["epic_id"] != "epic-1" || args["wave_id"] != "wave-2" {
		t.Fatalf("correction args = %#v, want only epic_id/wave_id", args)
	}

	rawURL := applyQuery("https://example.test/v1/cycles/epic-1/wave-2/open", globals{}, cmd, flags, args)
	if rawURL != "https://example.test/v1/cycles/epic-1/wave-2/open" {
		t.Fatalf("correction contract leaked into URL: %s", rawURL)
	}
	body, _, contentType, err := buildBodyWithStdinOwnership(cmd, flags, args, false)
	if err != nil {
		t.Fatalf("buildBody correction mode: %v", err)
	}
	if contentType != "application/json" {
		t.Fatalf("content type = %q, want application/json", contentType)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode correction body: %v", err)
	}
	if got["correction_of_json"] != correction || got["correction_of_digest"] != "sha256:abc" {
		t.Fatalf("correction body = %#v", got)
	}
}

func TestCycleOpenStandardPositionalContractRemainsCompatible(t *testing.T) {
	cmd := cycleOpenCorrectionCommand()
	pos, flags, err := splitArgs(cmd, []string{
		"epic-1", "wave-1", "legendary", `[{"unit_id":"u1"}]`, `{"scale_count":5}`,
	})
	if err != nil {
		t.Fatalf("splitArgs: %v", err)
	}
	args, err := bindArgs(cmd, pos)
	if err != nil {
		t.Fatalf("bindArgs standard mode: %v", err)
	}
	body, _, contentType, err := buildBodyWithStdinOwnership(cmd, flags, args, false)
	if err != nil {
		t.Fatalf("buildBody standard mode: %v", err)
	}
	if contentType != "application/json" {
		t.Fatalf("content type = %q, want application/json", contentType)
	}

	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode standard body: %v", err)
	}
	if got["profile"] != "legendary" || got["inventory_json"] != `[{"unit_id":"u1"}]` || got["scale_contract_json"] != `{"scale_count":5}` {
		t.Fatalf("standard body = %#v", got)
	}
}
