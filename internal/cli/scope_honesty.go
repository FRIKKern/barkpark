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
//
// TWO AXES, ONE SEAM. The -w/-p block below is the original. The dataset block
// after it is the same contract for -d (internal/manifest/dataset_scope.go),
// which was split out of the first change on purpose and is now built. When
// BOTH apply the -w/-p refusal is the one reported, because it is the more
// severe failure: a dropped -w answers about another TENANT, a dropped -d about
// another dataset inside the workspace the operator already named. Reporting one
// at a time also keeps the message a single actionable sentence — fixing the
// workspace re-runs the command, and the dataset refusal is then right there.
//
// `roster` is the full command list the CLI was served this invocation. Only the
// dataset half reads it, and only to DERIVE the remedy it names — see
// manifest.DatasetCarryingSiblings for why that sentence may not be frozen in
// prose. A nil roster is legal and simply drops the derived clause.
func refuseUnrepresentableScope(cmd manifest.Command, ctx manifest.Context, roster []manifest.Command) string {
	if msg := refuseUnrepresentableWorkspaceScope(cmd, ctx); msg != "" {
		return msg
	}
	return refuseUnrepresentableDataset(cmd, ctx, roster)
}

// refuseUnrepresentableDataset is the -d half. It fires ONLY when the operator
// TYPED a dataset that diverges from the baked floor (manifest.StatedDataset
// ANDs provenance with divergence — see its doc comment for the three conjuncts
// and the door each one closes) and the command can neither put it in its path
// nor forward it as a declared `dataset` flag.
//
// It returns an empty string for every ambient dataset — BARKPARK_DATASET, a
// repo .barkpark.json, the saved active config, a `-s <entry>`'s saved dataset —
// and for every typed -d that names the floor. Those are the cases that are
// CORRECT today, and they keep byte-identical behaviour.
func refuseUnrepresentableDataset(cmd manifest.Command, ctx manifest.Context, roster []manifest.Command) string {
	if !manifest.StatedDataset(ctx) {
		return ""
	}
	if manifest.DatasetFateFor(cmd) != manifest.DatasetRefused {
		return ""
	}

	verb := strings.TrimSpace(cmd.Noun + " " + cmd.Verb)
	why := "no dataset-scoped route or `dataset` parameter is declared for it"
	if d, ok := manifest.DatasetDispositionFor(cmd); ok && d.Reason != "" {
		why = d.Reason
	}

	// The remedy, DERIVED from the roster this invocation was served rather than
	// remembered in the Reason string. The generic `bp capabilities` clause stays
	// as the answer for a family with no carrying door at all.
	remedy := ""
	if siblings := manifest.DatasetCarryingSiblings(roster, cmd.Noun); len(siblings) > 0 {
		quoted := make([]string, 0, len(siblings))
		for _, s := range siblings {
			quoted = append(quoted, "`bp "+s+"`")
		}
		remedy = fmt.Sprintf(" In this family %s %s the dataset.",
			strings.Join(quoted, ", "), pluralCarry(len(siblings)))
	}

	return fmt.Sprintf(
		"`bp %s` cannot carry -d %s — %s. Sending it anyway would answer about "+
			"%q while you asked about %q, and exit 0. Drop the flag to accept the "+
			"server's default dataset, or use a command whose route carries the "+
			"dataset (`bp capabilities` marks them).%s",
		verb, ctx.Dataset, why,
		manifest.DefaultDefaults().Dataset, ctx.Dataset,
		remedy,
	)
}

// pluralCarry keeps the derived clause grammatical for a one-verb family, which
// is the common case and the one the frozen prose used to get right by accident.
func pluralCarry(n int) string {
	if n == 1 {
		return "carries"
	}
	return "carry"
}

// refuseUnrepresentableWorkspaceScope is the original -w/-p half, unchanged.
func refuseUnrepresentableWorkspaceScope(cmd manifest.Command, ctx manifest.Context) string {
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
