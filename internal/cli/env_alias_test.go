package cli

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// axi-b4-barkpark-url-env-footgun — THE ENV DIALECT, PROVEN BOTH WAYS.
//
// The defect: `bp` read BARKPARK_API_URL/BARKPARK_SERVER and BARKPARK_API_TOKEN
// and NOTHING else, while BARKPARK_TOKEN is the canonical name for the same
// concept in web/lib/bp-env.ts, in templates/DEPLOYING.md, and in the env the
// site deploy path injects into every customer build — and BARKPARK_URL is set
// by the release-capture adapter. Setting either did not fail loudly: an unset
// Token falls through to bakedDefaults()'s WELL-KNOWN "barkpark-dev-token", so
// the CLI silently authenticated as the dev user with a token the operator had
// just replaced.
//
// Every test here sets the env through t.Setenv, which restores on cleanup, and
// CLEARS the whole dialect first via the SHARED clearBarkparkEnv helper — a
// stray BARKPARK_API_TOKEN in the runner's environment would make the alias
// arms vacuously green. The helper derives its list from ServerEnvNames /
// TokenEnvNames, so it can never fall behind the dialect again.

func TestEnvContextAliasesTakeEffect(t *testing.T) {
	clearBarkparkEnv(t)
	t.Setenv("BARKPARK_URL", "https://alias.example")
	t.Setenv("BARKPARK_TOKEN", "alias-token")

	got := envContext()
	if got.BaseURL != "https://alias.example" {
		t.Errorf("BARKPARK_URL did not reach the resolver: BaseURL = %q, want %q", got.BaseURL, "https://alias.example")
	}
	if got.Token != "alias-token" {
		t.Errorf("BARKPARK_TOKEN did not reach the resolver: Token = %q, want %q", got.Token, "alias-token")
	}
}

// THE CANONICAL NAME WINS. A silent alias that OVERRODE the canonical name
// would be a worse footgun than the one it fixes: an operator who sets the
// documented name would be overridden by a legacy name they forgot was exported.
func TestEnvContextCanonicalBeatsAlias(t *testing.T) {
	clearBarkparkEnv(t)
	for _, c := range []struct {
		name             string
		canonical, alias string
		set              map[string]string
		wantURL, wantTok string
	}{
		{
			name: "API_URL beats SERVER beats URL",
			set: map[string]string{
				"BARKPARK_API_URL": "https://canonical.example",
				"BARKPARK_SERVER":  "https://middle.example",
				"BARKPARK_URL":     "https://legacy.example",
			},
			wantURL: "https://canonical.example",
		},
		{
			name: "SERVER beats URL when API_URL is unset",
			set: map[string]string{
				"BARKPARK_SERVER": "https://middle.example",
				"BARKPARK_URL":    "https://legacy.example",
			},
			wantURL: "https://middle.example",
		},
		{
			name: "API_TOKEN beats TOKEN",
			set: map[string]string{
				"BARKPARK_API_TOKEN": "canonical-token",
				"BARKPARK_TOKEN":     "legacy-token",
			},
			wantTok: "canonical-token",
		},
	} {
		t.Run(c.name, func(t *testing.T) {
			clearBarkparkEnv(t)
			for k, v := range c.set {
				t.Setenv(k, v)
			}
			got := envContext()
			if c.wantURL != "" && got.BaseURL != c.wantURL {
				t.Errorf("BaseURL = %q, want %q", got.BaseURL, c.wantURL)
			}
			if c.wantTok != "" && got.Token != c.wantTok {
				t.Errorf("Token = %q, want %q", got.Token, c.wantTok)
			}
		})
	}
}

// NOTHING SET STAYS EMPTY, so a lower layer (persisted config, baked defaults)
// still wins. An alias that returned a non-empty floor would silently outrank
// the user's saved active server.
func TestEnvContextEmptyWhenNothingSet(t *testing.T) {
	clearBarkparkEnv(t)
	got := envContext()
	if got.BaseURL != "" || got.Token != "" {
		t.Errorf("an unset dialect must leave the env layer EMPTY so config/defaults can win; got BaseURL=%q Token=%q", got.BaseURL, got.Token)
	}
}

// THE SOURCE LABELS DO NOT LIE. Both `bp whoami`'s "source" and the TUI's
// startup banner answer "where did this server come from". Before this row they
// asked a hand-written two-name question while the resolver honoured three, so
// an alias-configured server was reported as "saved" or "default" — a label
// that sends the next person to change the wrong thing.
func TestSourceLabelsSeeEveryAlias(t *testing.T) {
	for _, name := range ServerEnvNames {
		t.Run(name, func(t *testing.T) {
			clearBarkparkEnv(t)
			t.Setenv(name, "https://alias.example")
			if got := ServerSource(); got != "env" {
				t.Errorf("ServerSource() = %q with %s set, want \"env\" — the TUI banner would name the wrong origin", got, name)
			}
			src, _, _ := whoamiSourceName(globals{}, manifest.Context{Server: "https://alias.example"})
			if src != "env" {
				t.Errorf("whoamiSourceName = %q with %s set, want \"env\" — bp whoami would blame config for a server the environment chose", src, name)
			}
		})
	}
}

// AND THEY STAY HONEST WHEN NOTHING IS SET: a label that answered "env"
// unconditionally would pass the arm above while telling every user the same
// lie in the other direction.
func TestSourceLabelsAreNotEnvWhenUnset(t *testing.T) {
	clearBarkparkEnv(t)
	if got := ServerSource(); got == "env" {
		t.Errorf("ServerSource() = %q with the whole dialect unset, want anything but \"env\"", got)
	}
}

// THE TWO ALIAS CHAINS AGREE. apiclient sits BELOW cli and must not import it,
// so its ConfigFromEnv duplicates the chain by hand. That duplicate is exactly
// the thing that rots: this reads apiclient's source and asserts it names every
// element of both lists, in order, so adding a name here reds there.
func TestApiclientChainMatchesTheCliChain(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "apiclient", "client.go"))
	if err != nil {
		t.Fatalf("cannot read apiclient/client.go — the drift guard cannot run: %v", err)
	}
	body := string(src)
	i := strings.Index(body, "func ConfigFromEnv() Config {")
	if i < 0 {
		t.Fatal("apiclient.ConfigFromEnv is gone — re-point this drift guard rather than deleting it")
	}
	fn := body[i:]
	if j := strings.Index(fn, "\n}\n"); j > 0 {
		fn = fn[:j]
	}
	for _, chain := range [][]string{ServerEnvNames, TokenEnvNames} {
		var quoted []string
		for _, n := range chain {
			quoted = append(quoted, regexp.QuoteMeta(`"`+n+`"`))
		}
		re := regexp.MustCompile(`firstEnv\(` + strings.Join(quoted, `, `) + `\)`)
		if !re.MatchString(fn) {
			t.Errorf("apiclient.ConfigFromEnv does not resolve the chain %v in order — the two layers now answer to different env names", chain)
		}
	}
}
