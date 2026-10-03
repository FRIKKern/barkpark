package cli

// barkparks_adopt_cmd.go — `bp barkparks adopt`: attach an already-running box
// to the current Cloud team (POST /v1/barkparks/adopt).
//
// The box admin token proves control. It never rides argv (a global `--token`
// already means "this server's token", and argv lands in shell history and
// `ps`): it comes from a file (--token-file) or from the bp config entry saved
// for that url (--token-from-config). The control plane uses it for three
// requests, mints its OWN admin credential on the box labelled
// "barkpark cloud admin", stores that one, and returns no secret at all.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

const barkparksAdoptUsage = "bp barkparks adopt --url https://<box> --host <public-ip> --name <name> [--slug <slug>] (--token-file <path> | --token-from-config)"

type barkparksAdoptArgs struct {
	url, host, name, slug, tokenFile string
	fromConfig                       bool
}

func parseBarkparksAdoptArgs(args []string) (barkparksAdoptArgs, error) {
	var a barkparksAdoptArgs
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := splitTokenFlag(args[i])
		if name == "" {
			return a, fmt.Errorf("unexpected argument %q (usage: %s)", args[i], barkparksAdoptUsage)
		}
		if name == "token-from-config" {
			if hasInline && inline != "true" {
				return a, fmt.Errorf("--token-from-config takes no value (usage: %s)", barkparksAdoptUsage)
			}
			a.fromConfig = true
			continue
		}
		if name == "admin-token" || name == "token" {
			return a, fmt.Errorf("the box admin token never rides the command line — put it in a file and pass --token-file <path>, or use --token-from-config")
		}
		value := inline
		if !hasInline {
			if i+1 >= len(args) {
				return a, fmt.Errorf("--%s needs a value (usage: %s)", name, barkparksAdoptUsage)
			}
			i++
			value = args[i]
		}
		value = strings.TrimSpace(value)
		switch name {
		case "url":
			a.url = value
		case "host":
			a.host = value
		case "name":
			a.name = value
		case "slug":
			a.slug = value
		case "token-file":
			a.tokenFile = value
		default:
			return a, fmt.Errorf("unknown flag --%s (usage: %s)", name, barkparksAdoptUsage)
		}
	}
	switch {
	case a.url == "" || a.host == "" || a.name == "":
		return a, fmt.Errorf("--url, --host and --name are required (usage: %s)", barkparksAdoptUsage)
	case !strings.HasPrefix(strings.ToLower(a.url), "https://"):
		return a, fmt.Errorf("--url must be the box's https:// address — Cloud sends admin credentials to it and refuses plain http")
	case a.tokenFile == "" && !a.fromConfig:
		return a, fmt.Errorf("give the box admin token with --token-file <path> or --token-from-config (usage: %s)", barkparksAdoptUsage)
	case a.tokenFile != "" && a.fromConfig:
		return a, fmt.Errorf("--token-file and --token-from-config are exclusive — pick one")
	}
	if a.slug == "" {
		a.slug = adoptSlug(a.name)
	}
	return a, nil
}

var adoptSlugJunk = regexp.MustCompile(`[^a-z0-9]+`)

// adoptSlug folds a display name into the control plane's slug shape:
// lowercase alphanumerics joined by single hyphens, at most 63 characters.
func adoptSlug(name string) string {
	s := strings.Trim(adoptSlugJunk.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if len(s) > 63 {
		s = strings.TrimRight(s[:63], "-")
	}
	return s
}

// adoptToken reads the box admin token from the named source. The error never
// carries the token.
func adoptToken(cfg *Config, a barkparksAdoptArgs) (string, error) {
	if a.tokenFile != "" {
		raw, err := os.ReadFile(a.tokenFile)
		if err != nil {
			return "", fmt.Errorf("read --token-file: %v", err)
		}
		tok := strings.TrimSpace(string(raw))
		if tok == "" {
			return "", fmt.Errorf("--token-file %s is empty", a.tokenFile)
		}
		return tok, nil
	}
	want := normalizeServerURL(a.url)
	if normalizeServerURL(cfg.Server) == want {
		if t := strings.TrimSpace(cfg.AdminToken); t != "" {
			return t, nil
		}
		if t := strings.TrimSpace(cfg.Token); t != "" {
			return t, nil
		}
	}
	if e, ok := cfg.FindServer(a.url); ok && strings.TrimSpace(e.Token) != "" {
		return strings.TrimSpace(e.Token), nil
	}
	return "", fmt.Errorf("no token is saved in your bp config for %s — pass --token-file <path> instead", a.url)
}

func runBarkparksAdopt(out *writer, args []string) int {
	a, err := parseBarkparksAdoptArgs(args)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}
	token, terr := adoptToken(cfg, a)
	if terr != nil {
		return useError(out, "usage", terr.Error(), exitUsage)
	}

	res, aerr := cfg.CloudClient().AdoptBarkpark(context.Background(), cloudclient.AdoptRequest{
		Name:       a.name,
		Slug:       a.slug,
		URL:        a.url,
		Host:       a.host,
		AdminToken: token,
	})
	if aerr != nil {
		return cloudFail(out, "adopt "+a.url, aerr)
	}

	var envelope map[string]any
	if json.Unmarshal(res.Raw, &envelope) == nil && out.emitStructured(envelope) {
		return exitOK
	}

	bp := res.Barkpark
	out.outf("Attached %s (%s) — %s", bp.Name, bp.ID, bp.URL)
	for _, step := range []string{"credential", "self_update", "autoupdate", "monitoring_agent"} {
		s, present := res.Adopted.Armed[step]
		if !present {
			continue
		}
		line := fmt.Sprintf("  %-17s %-14s", step, s.Status)
		if s.Detail != "" {
			line += " " + s.Detail
		}
		out.outf("%s", strings.TrimRight(line, " "))
	}
	out.outf("Box workspace %s · Cloud's credential id %s (label %q)", res.Adopted.Workspace, res.Adopted.CredentialID, res.Adopted.CredentialLabel)
	out.outf("Your token proved control and was not stored. You can revoke it on the box; Cloud keeps working on its own credential.")
	return exitOK
}
