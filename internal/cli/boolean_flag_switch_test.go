package cli

import (
	"net/url"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// The live manifest declares `access grant --single_use` with type "boolean"
// (api capabilities.ex), while every other switch is typed "bool". Both
// spellings must parse as a value-less switch. Before IsSwitch, "boolean" fell
// into the value-flag branch: a trailing `--single_use` answered "needs a
// value", and `--single_use --dataset x` refused the same way.
func accessGrantCmd() manifest.Command {
	return manifest.Command{
		ID: "access.grant", Noun: "access", Verb: "grant", Writes: true,
		Args: []manifest.Arg{
			{Name: "grantee_email", Type: "string", Required: true},
			{Name: "workspace_id", Type: "string", Required: true},
			{Name: "capabilities", Type: "string", Required: true},
		},
		Flags: []manifest.Flag{
			{Name: "dataset", Type: "string"},
			{Name: "single_use", Type: "boolean"},
		},
	}
}

func TestBooleanTypedFlagIsASwitch(t *testing.T) {
	cmd := accessGrantCmd()
	pos, flags, err := splitArgs(cmd, []string{"a@b.no", "ws", "read", "--single_use", "--dataset", "production"})
	if err != nil {
		t.Fatalf("--single_use (type boolean) must parse as a switch: %v", err)
	}
	if got := strings.Join(pos, ","); got != "a@b.no,ws,read" {
		t.Errorf("positionals = %q", got)
	}
	if v := flags["single_use"]; len(v) != 1 || v[0] != "true" {
		t.Errorf("single_use = %v, want [true]", v)
	}
	if v := flags["dataset"]; len(v) != 1 || v[0] != "production" {
		t.Errorf("dataset = %v, want [production]", v)
	}

	// A trailing switch has no following token, and that is not an error.
	_, flags, err = splitArgs(cmd, []string{"a@b.no", "ws", "read", "--single_use"})
	if err != nil || len(flags["single_use"]) != 1 || flags["single_use"][0] != "true" {
		t.Errorf("trailing --single_use: flags=%v err=%v", flags, err)
	}

	// An inline value on a switch is refused for both spellings, as for "bool".
	if _, _, err := splitArgs(cmd, []string{"a@b.no", "ws", "read", "--single_use=false"}); err == nil || !strings.Contains(err.Error(), "takes no value") {
		t.Errorf("--single_use=false must be refused as 'takes no value'; err=%v", err)
	}

	// A set switch rides the query as ?single_use=true.
	got := applyQuery("https://x.test/v1/access/grants", globals{}, cmd, map[string][]string{"single_use": {"true"}}, map[string]string{})
	u, _ := url.Parse(got)
	if u.Query().Get("single_use") != "true" {
		t.Errorf("single_use should ride as ?single_use=true; got %q", got)
	}

	// The MCP tail rebuild emits the bare switch, never `--single_use true`.
	tail := buildCommandTail(cmd, map[string]any{
		"grantee_email": "a@b.no", "workspace_id": "ws", "capabilities": "read", "single_use": true,
	})
	if j := strings.Join(tail, " "); !strings.HasSuffix(j, "--single_use") {
		t.Errorf("MCP tail should end in the bare switch; got %q", j)
	}
}

func TestFlagIsSwitch(t *testing.T) {
	for typ, want := range map[string]bool{"bool": true, "boolean": true, "string": false, "int": false, "file": false, "": false} {
		if got := (manifest.Flag{Type: typ}).IsSwitch(); got != want {
			t.Errorf("Flag{Type:%q}.IsSwitch() = %v, want %v", typ, got, want)
		}
	}
}
