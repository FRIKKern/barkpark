package cli

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// builtinWritePoison is one row of the poison table — the SIX bodies wave 29
// measured a stated success over. They are the same six the manifest fence and
// the MCP fence are proved against, deliberately: one discriminator, one table,
// so a class that passes here is provably in the same regime as `bp doc create`.
type builtinWritePoison struct {
	name string
	body string
}

var builtinWritePoisons = []builtinWritePoison{
	{"empty_object", `{}`},
	{"json_null", `null`},
	{"result_null", `{"result":null}`},
	{"undeclared_empty_200", ``},
	{"html_proxy_page", "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"},
	{"error_envelope_on_2xx", `{"ok":false,"error":{"code":"internal_error","message":"boom"}}`},
}

// namesTheRefusal is the ONE assertion every screened class shares: the output
// must name the shared class, not merely be non-empty. A refusal that says
// nothing recognisable is the failure mode this whole epic is about.
func namesTheRefusal(s string) bool {
	return strings.Contains(s, "unreadable write receipt") ||
		strings.Contains(s, "unreadable_write_receipt")
}

// ---------------------------------------------------------------------------
// seed — the loudest machine-rendered class
// ---------------------------------------------------------------------------

// seedServer answers the schema GET honestly and hands `bodies` out to the
// successive mutate POSTs (the createOrReplace batch, then the --publish batch).
func seedServer(t *testing.T, bodies ...string) *httptest.Server {
	t.Helper()
	n := 0
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = io.WriteString(w, `{"schemas":[{"name":"post","fields":[{"name":"title","type":"string"}]}]}`)
			return
		}
		body := bodies[len(bodies)-1]
		if n < len(bodies) {
			body = bodies[n]
		}
		n++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, body)
	}))
}

const seedHonestMutateBody = `{"results":[{"id":"drafts.seed-post-1","operation":"update"}]}`

func TestSeedPoisonedMutateReceiptRefuses(t *testing.T) {
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			srv := seedServer(t, p.body)
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = "json"
			code := runSeed(w, globals{}, manifest.Context{Server: srv.URL, Dataset: "production"},
				[]string{"post", "--count", "1"})
			if code == exitOK {
				t.Fatalf("exit = 0 over a poisoned mutate receipt; stdout=%q stderr=%q", so.String(), se.String())
			}
			if !namesTheRefusal(so.String() + se.String()) {
				t.Fatalf("refusal does not name the class: stdout=%q stderr=%q", so.String(), se.String())
			}
		})
	}
}

// TestSeedPoisonedPublishReceiptRefuses is the SECOND site in runSeed: the
// create batch answers honestly and only the --publish follow-up is poisoned.
// Without its own screen this printed `"published": true` at rc=0.
func TestSeedPoisonedPublishReceiptRefuses(t *testing.T) {
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			srv := seedServer(t, seedHonestMutateBody, p.body)
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = "json"
			code := runSeed(w, globals{}, manifest.Context{Server: srv.URL, Dataset: "production"},
				[]string{"post", "--count", "1", "--publish"})
			if code == exitOK {
				t.Fatalf("exit = 0 over a poisoned PUBLISH receipt; stdout=%q stderr=%q", so.String(), se.String())
			}
			if !namesTheRefusal(so.String() + se.String()) {
				t.Fatalf("refusal does not name the class: stdout=%q stderr=%q", so.String(), se.String())
			}
		})
	}
}

// TestSeedHonestReceiptIsByteIdentical is criterion c3's counterweight AND this
// file's non-vacuity guard: it pins the EXACT bytes an honest seed prints in
// both the text and json shapes. A fence that refused everything would red
// here, so the reds above are statements about poison, not about seed.
//
// The strings below were captured on origin/main (775db06e4) BEFORE the screen
// existed, by running the same two drivers against the same fixture server.
func TestSeedHonestReceiptIsByteIdentical(t *testing.T) {
	t.Run("text", func(t *testing.T) {
		srv := seedServer(t, seedHonestMutateBody)
		defer srv.Close()
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.output = "table"
		code := runSeed(w, globals{}, manifest.Context{Server: srv.URL, Dataset: "production"},
			[]string{"post", "--count", "1"})
		const want = "seeded 1 post draft(s) into production\n  seed-post-1\n"
		if code != exitOK || so.String() != want {
			t.Fatalf("exit=%d stdout=%q, want exit=0 stdout=%q (stderr=%q)", code, so.String(), want, se.String())
		}
	})
	t.Run("json_publish", func(t *testing.T) {
		srv := seedServer(t, seedHonestMutateBody, seedHonestMutateBody)
		defer srv.Close()
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.output = "json"
		code := runSeed(w, globals{}, manifest.Context{Server: srv.URL, Dataset: "production"},
			[]string{"post", "--count", "1", "--publish"})
		if code != exitOK {
			t.Fatalf("exit=%d over an honest publish (stderr=%q)", code, se.String())
		}
		const want = `{"count":1,"dataset":"production","ids":["seed-post-1"],"ok":true,"published":true,"type":"post"}` + "\n"
		if so.String() != want {
			t.Fatalf("honest json receipt is not byte-identical:\n got %q\nwant %q", so.String(), want)
		}
	})
}

// ---------------------------------------------------------------------------
// migrate — the schema POST that counted statuses
// ---------------------------------------------------------------------------

func TestMigrateSchemasPoisonedReceiptRefuses(t *testing.T) {
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = io.WriteString(w, `{"schemas":[{"name":"post","fields":[{"name":"title","type":"string"}]}]}`)
			}))
			defer src.Close()
			dst := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, p.body)
			}))
			defer dst.Close()

			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			plan := migratePlan{
				from:    migrateEndpoint{name: "src", url: src.URL, workspace: "default", project: "default"},
				to:      migrateEndpoint{name: "dst", url: dst.URL, workspace: "default", project: "default"},
				dataset: "production",
			}
			count, errs := migrateSchemas(w, false, plan)
			if count != 0 {
				t.Fatalf("counted %d schemas POSTed over a poisoned receipt", count)
			}
			if len(errs) != 1 || !namesTheRefusal(errs[0]) {
				t.Fatalf("errs = %v, want one naming the unreadable write receipt", errs)
			}
			if strings.Contains(so.String(), "✓ schemas") {
				t.Fatalf("printed a schema checkmark over a poisoned receipt: %q", so.String())
			}
		})
	}
}

// TestMigrateSchemasHonestReceiptIsByteIdentical pins the honest line.
func TestMigrateSchemasHonestReceiptIsByteIdentical(t *testing.T) {
	src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"schemas":[{"name":"post","fields":[{"name":"title","type":"string"}]}]}`)
	}))
	defer src.Close()
	dst := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"name":"post","ok":true}`)
	}))
	defer dst.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	count, errs := migrateSchemas(w, false, migratePlan{
		from:    migrateEndpoint{name: "src", url: src.URL, workspace: "default", project: "default"},
		to:      migrateEndpoint{name: "dst", url: dst.URL, workspace: "default", project: "default"},
		dataset: "production",
	})
	const want = "  ✓ schemas: 1 POSTed to target\n"
	if count != 1 || len(errs) != 0 || so.String() != want {
		t.Fatalf("count=%d errs=%v stdout=%q, want 1 / none / %q", count, errs, so.String(), want)
	}
}

// ---------------------------------------------------------------------------
// tinker REPL mutate
// ---------------------------------------------------------------------------

func TestTinkerMutatePoisonedReceiptRefuses(t *testing.T) {
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, p.body)
			}))
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			tinkerRequest(w, "POST", srv.URL, map[string]string{"Content-Type": "application/json"},
				[]byte(`{"mutations":[]}`))
			if !namesTheRefusal(so.String() + se.String()) {
				t.Fatalf("REPL mutate said nothing about a poisoned receipt: stdout=%q stderr=%q", so.String(), se.String())
			}
		})
	}
}

// TestTinkerReadOverEmptyListStillRenders is the OVER-REFUSAL guard for the
// method gate in tinkerRequest: `query` shares the helper, an honest empty query
// answers `[]`, and the write verdict refuses an empty array. If the gate is
// ever dropped, this reds.
func TestTinkerReadOverEmptyListStillRenders(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `[]`)
	}))
	defer srv.Close()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	tinkerRequest(w, "GET", srv.URL, nil, nil)
	if namesTheRefusal(so.String() + se.String()) {
		t.Fatalf("an honest empty QUERY was refused by the write fence: stdout=%q stderr=%q", so.String(), se.String())
	}
	if !strings.Contains(so.String(), "[]") {
		t.Fatalf("empty query lost its body: stdout=%q", so.String())
	}
}

// ---------------------------------------------------------------------------
// vercel deploy steps — the ✓ checkmarks printed off a status
// ---------------------------------------------------------------------------

func TestVercelDeployStepsPoisonedReceiptsRefuse(t *testing.T) {
	dir := t.TempDir()
	schemaFile := filepath.Join(dir, "schema.json")
	if err := os.WriteFile(schemaFile, []byte(`{"name":"post","fields":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	seedFile := filepath.Join(dir, "seed.json")
	if err := os.WriteFile(seedFile, []byte(`{"mutations":[{"createOrReplace":{"_id":"p1","_type":"post"}}]}`), 0o600); err != nil {
		t.Fatal(err)
	}

	steps := []struct {
		name string
		run  func(out *writer, base string) error
	}{
		{"workspace_create", func(out *writer, base string) error {
			return vercelEnsureWorkspace(out, base, "tok", "site")
		}},
		{"schema_apply", func(out *writer, base string) error {
			return vercelApplySchema(out, base, "production", "tok", schemaFile)
		}},
		{"seed_mutate", func(out *writer, base string) error {
			return vercelSeed(out, base, "production", "tok", seedFile, "")
		}},
	}
	for _, st := range steps {
		for _, p := range builtinWritePoisons {
			t.Run(st.name+"/"+p.name, func(t *testing.T) {
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					w.WriteHeader(http.StatusOK)
					_, _ = io.WriteString(w, p.body)
				}))
				defer srv.Close()
				var so, se bytes.Buffer
				w := newWriter(&so, &se)
				err := st.run(w, srv.URL)
				if err == nil {
					t.Fatalf("step returned nil over a poisoned receipt; stdout=%q stderr=%q", so.String(), se.String())
				}
				if !namesTheRefusal(err.Error()) {
					t.Fatalf("error does not name the class: %v", err)
				}
				if strings.Contains(so.String()+se.String(), "✓") {
					t.Fatalf("printed a checkmark over a poisoned receipt: %q / %q", so.String(), se.String())
				}
			})
		}
	}
}

// TestVercelSeedPublishPoisonedReceiptRefuses is vercelSeed's SECOND site: the
// seed batch answers honestly and only the publish follow-up is poisoned.
func TestVercelSeedPublishPoisonedReceiptRefuses(t *testing.T) {
	dir := t.TempDir()
	seedFile := filepath.Join(dir, "seed.json")
	if err := os.WriteFile(seedFile, []byte(`{"mutations":[{"createOrReplace":{"_id":"p1","_type":"post"}}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			n := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				n++
				w.WriteHeader(http.StatusOK)
				if n == 1 {
					_, _ = io.WriteString(w, `{"results":[{"id":"p1"}]}`)
					return
				}
				_, _ = io.WriteString(w, p.body)
			}))
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			err := vercelSeed(w, srv.URL, "production", "tok", seedFile, "post")
			if err == nil || !namesTheRefusal(err.Error()) {
				t.Fatalf("publish step err = %v, want a named unreadable-write-receipt refusal", err)
			}
			if strings.Contains(so.String()+se.String(), "published") {
				t.Fatalf("claimed a publish over a poisoned receipt: %q / %q", so.String(), se.String())
			}
		})
	}
}

// TestVercelDeployStepsHonestReceiptsUnchanged pins every ✓ line the flow
// prints on an honest server — the counterweight for the reds above.
func TestVercelDeployStepsHonestReceiptsUnchanged(t *testing.T) {
	dir := t.TempDir()
	seedFile := filepath.Join(dir, "seed.json")
	if err := os.WriteFile(seedFile, []byte(`{"mutations":[{"createOrReplace":{"_id":"p1","_type":"post"}}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"results":[{"id":"p1"}]}`)
	}))
	defer srv.Close()

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if err := vercelEnsureWorkspace(w, srv.URL, "tok", "site"); err != nil {
		t.Fatalf("honest workspace create: %v", err)
	}
	if err := vercelSeed(w, srv.URL, "production", "tok", seedFile, "post"); err != nil {
		t.Fatalf("honest seed+publish: %v", err)
	}
	got := so.String() + se.String()
	for _, want := range []string{
		"  ✓ workspace 'site' created",
		"  ✓ seeded (createOrReplace lands as drafts)",
		"  ✓ published 1 document(s) of type 'post'",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("honest flow lost %q:\n%s", want, got)
		}
	}
}

// ---------------------------------------------------------------------------
// chat unarchive — the #15917 shape on the CLI side
// ---------------------------------------------------------------------------

func TestChatUnarchivePoisonedReceiptRefuses(t *testing.T) {
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, p.body)
			}))
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			code := runChatUnarchive(w, globals{}, manifest.Context{Server: srv.URL}, []string{"sess-1"})
			if code == exitOK {
				t.Fatalf("exit = 0 over a poisoned unarchive receipt; stdout=%q stderr=%q", so.String(), se.String())
			}
			if strings.Contains(so.String(), "unarchived") {
				t.Fatalf("printed an unarchive receipt over a poisoned body: %q", so.String())
			}
			if !namesTheRefusal(so.String() + se.String()) {
				t.Fatalf("refusal does not name the class: stdout=%q stderr=%q", so.String(), se.String())
			}
		})
	}
}

// TestChatUnarchiveHonestReceiptIsByteIdentical pins the honest line.
func TestChatUnarchiveHonestReceiptIsByteIdentical(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"id":"sess-1","title":"a session"}`)
	}))
	defer srv.Close()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	code := runChatUnarchive(w, globals{}, manifest.Context{Server: srv.URL}, []string{"sess-1"})
	const want = "unarchived sess-1  a session\n"
	if code != exitOK || so.String() != want {
		t.Fatalf("exit=%d stdout=%q, want 0 / %q (stderr=%q)", code, so.String(), want, se.String())
	}
}

// ---------------------------------------------------------------------------
// cloud workspace import — the renderRaw-verbatim receipt
// ---------------------------------------------------------------------------

func TestCloudWorkspaceImportPoisonedReceiptRefuses(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "ws.tar")
	if err := os.WriteFile(bundle, []byte("not-really-a-tar"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, p := range builtinWritePoisons {
		t.Run(p.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, p.body)
			}))
			defer srv.Close()
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = "json"
			code := runCloudWorkspaceImport(w, globals{server: srv.URL, yes: true, output: "json"},
				[]string{"ws", "--file", bundle})
			if code == exitOK {
				t.Fatalf("exit = 0 over a poisoned import receipt; stdout=%q stderr=%q", so.String(), se.String())
			}
			if !namesTheRefusal(so.String() + se.String()) {
				t.Fatalf("refusal does not name the class: stdout=%q stderr=%q", so.String(), se.String())
			}
		})
	}
}

// TestCloudWorkspaceImportHonestReceiptIsByteIdentical pins the honest human
// line — the counterweight for the import reds.
func TestCloudWorkspaceImportHonestReceiptIsByteIdentical(t *testing.T) {
	dir := t.TempDir()
	bundle := filepath.Join(dir, "ws.tar")
	if err := os.WriteFile(bundle, []byte("not-really-a-tar"), 0o600); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"tables":3,"total_rows":42}`)
	}))
	defer srv.Close()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"
	code := runCloudWorkspaceImport(w, globals{server: srv.URL, yes: true}, []string{"ws", "--file", bundle})
	if code != exitOK {
		t.Fatalf("exit=%d over an honest import (stdout=%q stderr=%q)", code, so.String(), se.String())
	}
	if !strings.Contains(so.String(), "Imported workspace ws") {
		t.Fatalf("honest import receipt changed: %q", so.String())
	}
}
