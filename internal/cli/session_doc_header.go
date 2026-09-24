package cli

import (
	"os"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE SESSION-DOC HEADER (task-9002f2b301329f1f — CLI half of
// task-bc34e83515bbd91f; server half PR #20024,
// api/lib/barkpark_web/session_autolog.ex).
//
// When a request names a type:session document in X-Barkpark-Session-Doc, the
// server appends the matching event to that session's trail after the primary
// write commits: `task-closed` from POST /v1/tasks/:doc_id/close and
// `paper-published` from POST /v1/plugins/bulldocs/papers. Until bp sends the
// header, that server code does nothing for any caller.
//
// NOT X-Barkpark-Session. That name carries the SECRET claim-session key
// (tasks_session_key.go), sent on every manifest request and never stored by
// the server. This header carries a PUBLIC slug the server writes into a
// document. The two ride side by side on the armed requests.
const sessionDocHeader = "X-Barkpark-Session-Doc"

// sessionDocCommands are the manifest commands whose server action arms the
// autolog: `plug(:arm_session_autolog when action in [:close])` in
// TasksController and `... in [:ingest]` in BulldocsIngestController. Every
// other route ignores the header, so sending it there would only put a slug on
// the wire that nothing reads — and would make every bp call look like it named
// a session doc, the exact ambiguity the server moduledoc refused. `bp paper
// push` rides the sync route, which the server does NOT arm, so it is not here.
var sessionDocCommands = map[string]bool{
	"task.close":       true,
	"bulldocs.publish": true,
}

// sessionDocFor resolves the bound session slug for cmd, or "" when cmd is not
// an armed door or no session is bound. Precedence, first non-blank wins:
//
//	--session <slug>        (this invocation)
//	BARKPARK_SESSION        (the process environment)
//	"session" in config.json (the saved binding)
//
// The env and config layers are AMBIENT — they describe the operator of this
// process — so they are read only when ctx.AmbientCredentialsOK, the same gate
// ingestSecret uses. `bp mcp serve --http` clears it, so a remote peer's close
// is never logged into the serving operator's session.
func sessionDocFor(g globals, ctx manifest.Context, cmd manifest.Command) string {
	if !sessionDocCommands[cmd.ID] {
		return ""
	}
	return sessionDocBinding(g, ctx)
}

// sessionDocBinding is the precedence walk above WITHOUT the armed-door gate —
// the one resolver for the bound slug. sessionDocFor gates it per manifest
// command; apiSessionConfig hands it to an apiclient whose only header-bearing
// door is the close (task-e4cbf4cd9f672c33), so both surfaces bind the same
// session under the same ambient rule.
func sessionDocBinding(g globals, ctx manifest.Context) string {
	if s := strings.TrimSpace(g.session); s != "" {
		return s
	}
	if !ctx.AmbientCredentialsOK {
		return ""
	}
	if s := strings.TrimSpace(os.Getenv("BARKPARK_SESSION")); s != "" {
		return s
	}
	if c, err := LoadConfig(); err == nil && c != nil {
		return strings.TrimSpace(c.Session)
	}
	return ""
}

// apiSessionConfig stamps the two session headers onto an apiclient.Config the
// CLI builds for a surface that closes tasks OUTSIDE buildManifestRequest — the
// desk TUI (ResolvedAPIConfig), the board (runTasksBoard) and the cmux Stop
// hook (newHookClient). apiclient sits below this package and cannot import
// these resolvers, so the values are resolved HERE, by the same sessionKey and
// sessionDocBinding the manifest path uses, and carried down as data.
func apiSessionConfig(cfg apiclient.Config, g globals, ctx manifest.Context) apiclient.Config {
	cfg.SessionKey = sessionKey()
	cfg.SessionDoc = sessionDocBinding(g, ctx)
	return cfg
}
