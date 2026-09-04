package cli

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// refuseUnrepresentableScope is the client-side half of the scope-honesty
// contract (internal/manifest/scope.go). BuildURL handles the two honest
// outcomes — the command's own path already reads the scope, or the server
// advertises a scoped_prefix and the request goes to the mirror. This function
// handles the third: the operator NAMED a workspace/project that this command's
// URL has nowhere to put, and no scoped mirror is advertised for it.
//
// Before this refusal, `bp -w gyldendal dataset stats` returned the DEFAULT
// workspace's numbers with exit 0. There is no way to make that request answer
// the question that was asked, so the only honest move left is to not send it.
//
// It returns an empty string when there is nothing to refuse — including for
// every invocation that leaves the scope at the baked floor, which is why no
// existing command line changes behaviour.
func refuseUnrepresentableScope(cmd manifest.Command, ctx manifest.Context) string {
	stated := manifest.StatedScope(ctx)
	if len(stated) == 0 {
		return ""
	}
	if manifest.ScopeFateFor(cmd) != manifest.ScopeRefused {
		return ""
	}

	// Name the values back, so the operator sees the scope that is about to be
	// dropped rather than just the flag letters.
	var named []string
	for _, f := range stated {
		switch f {
		case "-w":
			named = append(named, fmt.Sprintf("-w %s", ctx.Workspace))
		case "-p":
			named = append(named, fmt.Sprintf("-p %s", ctx.Project))
		}
	}

	verb := strings.TrimSpace(cmd.Noun + " " + cmd.Verb)
	why := "no workspace/project-scoped route is advertised for it"
	if d, ok := manifest.ScopeDispositionFor(cmd); ok && d.Reason != "" {
		why = d.Reason
	}

	return fmt.Sprintf(
		"`bp %s` cannot carry %s — %s. Sending it anyway would answer about %q "+
			"while you asked about %q, and exit 0. Drop the flag to accept the "+
			"server's default scope, or use a command whose route carries the "+
			"workspace (`bp capabilities` marks them).",
		verb, strings.Join(named, " "), why,
		manifest.DefaultDefaults().Workspace, ctx.Workspace,
	)
}
