package cli

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestTaskExecutionPolicyCLIParsesStrictTypedObject(t *testing.T) {
	body, _, err := parseTaskCreateArgs([]string{
		"policy task",
		"--execution-policy",
		`{"version":1,"agent_type":" executor ","model":"gpt-5.6-sol","reasoning_effort":"high","resource_class":"heavy"}`,
	})
	if err != nil {
		t.Fatalf("parse policy: %v", err)
	}
	policy, ok := body["execution_policy"].(map[string]any)
	if !ok {
		t.Fatalf("execution_policy = %#v, want object", body["execution_policy"])
	}
	if policy["agent_type"] != "executor" || policy["model"] != "gpt-5.6-sol" {
		t.Fatalf("sanitized policy = %#v", policy)
	}

	for _, raw := range []string{
		`{"version":2}`,
		`{"version":1,"command":"echo unsafe"}`,
		`{"version":1,"reasoning_effort":"unbounded"}`,
		`{"version":1,"resource_class":"root"}`,
	} {
		if _, _, err := parseTaskCreateArgs([]string{"bad", "--execution-policy", raw}); err == nil {
			t.Errorf("policy %s unexpectedly accepted", raw)
		}
	}
}

func TestTaskExecutionPolicyMCPCreateAndNextRoundTrip(t *testing.T) {
	var createBody, claimBody []byte
	requestCount := 0

	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		requestCount++
		switch {
		case strings.Contains(req.URL.Path, "/v1/data/mutate"):
			createBody, _ = io.ReadAll(req.Body)
			_, _ = io.WriteString(rw, `{"results":[{"id":"drafts.policy-task"}]}`)
		case req.URL.Path == "/v1/tasks/claim":
			claimBody, _ = io.ReadAll(req.Body)
			_, _ = io.WriteString(rw, `{"ok":true,"doc":{"doc_id":"policy-task"}}`)
		default:
			rw.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(rw, `{"error":{"code":"not_found"}}`)
		}
	}))
	defer ts.Close()

	m, err := manifest.Parse([]byte(mcpTestManifest))
	if err != nil {
		t.Fatalf("parse manifest: %v", err)
	}

	srv := mcp.NewServer(&mcp.Implementation{Name: "policy-test", Version: "0"}, nil)
	ctx := manifest.Context{Server: ts.URL, Token: "tok", Dataset: "production"}
	if err := registerTaskTools(srv, globals{yes: true}, ctx, m); err != nil {
		t.Fatalf("registerTaskTools: %v", err)
	}

	serverT, clientT := mcp.NewInMemoryTransports()
	bg := context.Background()
	ss, err := srv.Connect(bg, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	defer ss.Close()

	client := mcp.NewClient(&mcp.Implementation{Name: "policy-client", Version: "0"}, nil)
	cs, err := client.Connect(bg, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	policy := map[string]any{
		"version": 1, "agent_type": "executor", "model": "gpt-5.6-sol",
		"reasoning_effort": "high", "resource_class": "heavy",
	}

	createResult, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_create",
		Arguments: map[string]any{
			"title": "policy task", "publish": false, "execution_policy": policy,
		},
	})
	if err != nil || createResult.IsError {
		t.Fatalf("task_create policy failed: err=%v result=%s", err, mcpContentText(createResult))
	}

	var createEnvelope struct {
		Mutations []struct {
			Create map[string]any `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(createBody, &createEnvelope); err != nil {
		t.Fatalf("decode create body: %v (%s)", err, createBody)
	}
	createdPolicy := createEnvelope.Mutations[0].Create["execution_policy"].(map[string]any)
	if createdPolicy["agent_type"] != "executor" || createdPolicy["resource_class"] != "heavy" {
		t.Fatalf("created execution_policy = %#v", createdPolicy)
	}

	nextResult, err := cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_next",
		Arguments: map[string]any{
			"worker_id": "policy-worker", "execution_policy_override": policy,
		},
	})
	if err != nil || nextResult.IsError {
		t.Fatalf("task_next policy failed: err=%v result=%s", err, mcpContentText(nextResult))
	}

	var claim map[string]any
	if err := json.Unmarshal(claimBody, &claim); err != nil {
		t.Fatalf("decode claim body: %v (%s)", err, claimBody)
	}
	if claim["worker_id"] != "policy-worker" {
		t.Fatalf("claim worker_id = %#v", claim["worker_id"])
	}
	claimedPolicy, ok := claim["execution_policy_override"].(map[string]any)
	if !ok || claimedPolicy["model"] != "gpt-5.6-sol" {
		t.Fatalf("claim execution_policy_override = %#v", claim["execution_policy_override"])
	}

	beforeUnsafe := requestCount
	unsafeResult, unsafeErr := cs.CallTool(bg, &mcp.CallToolParams{
		Name: "task_next",
		Arguments: map[string]any{
			"worker_id":                 "policy-worker",
			"execution_policy_override": map[string]any{"version": 1, "command": "no"},
		},
	})
	if unsafeErr == nil && unsafeResult != nil && !unsafeResult.IsError {
		t.Fatal("unsafe MCP policy unexpectedly accepted")
	}
	if requestCount != beforeUnsafe {
		t.Fatalf("unsafe policy sent %d backend request(s)", requestCount-beforeUnsafe)
	}
}
