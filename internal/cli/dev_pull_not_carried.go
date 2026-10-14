package cli

// dev_pull_not_carried.go lists what a dev-profile bundle leaves behind on
// purpose and prints the commands that recreate it on the target.
//
// The dev profile denies `shares`, `api_tokens` and their kin
// (api/lib/barkpark/tenancy/workspace_bundle/catalog.ex, @dev_deny): copying an
// access registry or a credential to a laptop would reopen public surfaces or
// hand out production keys. That is the right call, and it also means a pulled
// workspace answers 401 or 403 where the source answered 200 until someone
// recreates the read token and the `:media` share by hand. The pull now says
// which ones, read from the source's own registry, and prints the command for
// each. It never recreates them itself: minting a credential is a decision for
// the person running the pull.
//
// The listing is read-only and best-effort. A source that refuses it (an
// older server, a token without admin) costs the pull nothing; the summary
// says the list could not be read and why.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type devPullShare struct {
	Scope    string   `json:"scope"`
	Project  string   `json:"project"`
	Dataset  string   `json:"dataset"`
	Surfaces []string `json:"surfaces"`
	Access   string   `json:"access"`
	Source   string   `json:"source"`
}

type devPullToken struct {
	Label       string   `json:"label"`
	Kind        string   `json:"kind"`
	Permissions []string `json:"permissions"`
	Dataset     string   `json:"dataset,omitempty"`
}

// devPullNotCarried is the part of the receipt that names what did not travel.
type devPullNotCarried struct {
	Shares   []devPullShare `json:"shares"`
	Tokens   []devPullToken `json:"tokens"`
	Commands []string       `json:"commands"`
	// Unread names a list the source would not give, with the reason.
	Unread []string `json:"unread,omitempty"`
}

// devPullListNotCarried reads the source's shares and token inventory for the
// pulled workspace and dataset, and builds the commands that recreate each one
// on the target server tgtName.
func devPullListNotCarried(srcBase, srcTok, ws, ds, project, tgtName string) devPullNotCarried {
	nc := devPullNotCarried{Shares: []devPullShare{}, Tokens: []devPullToken{}, Commands: []string{}}
	if project == "" {
		project = "default"
	}
	client := &http.Client{Timeout: 30 * time.Second}

	var shares struct {
		Shares []struct {
			devPullShare
			Workspace string `json:"workspace"`
		} `json:"shares"`
	}
	if err := devPullGetJSON(client, srcBase+"/v1/shares", srcTok, &shares); err != nil {
		nc.Unread = append(nc.Unread, "shares: "+err.Error())
	} else {
		for _, s := range shares.Shares {
			if s.Workspace != ws || s.Dataset != ds {
				continue
			}
			nc.Shares = append(nc.Shares, s.devPullShare)
		}
	}

	var tokens struct {
		Tokens []struct {
			devPullToken
			RevokedAt *string `json:"revoked_at"`
			ExpiresAt *string `json:"expires_at"`
		} `json:"tokens"`
	}
	tokURL := srcBase + "/w/" + url.PathEscape(ws) + "/p/" + url.PathEscape(project) + "/v1/tokens?limit=1000"
	if err := devPullGetJSON(client, tokURL, srcTok, &tokens); err != nil {
		nc.Unread = append(nc.Unread, "tokens: "+err.Error())
	} else {
		now := time.Now()
		for _, t := range tokens.Tokens {
			if t.RevokedAt != nil && *t.RevokedAt != "" {
				continue
			}
			if t.ExpiresAt != nil && *t.ExpiresAt != "" {
				if exp, err := time.Parse(time.RFC3339, *t.ExpiresAt); err == nil && exp.Before(now) {
					continue
				}
			}
			if t.Dataset != "" && t.Dataset != ds {
				continue
			}
			nc.Tokens = append(nc.Tokens, t.devPullToken)
		}
	}

	sort.SliceStable(nc.Shares, func(i, j int) bool { return nc.Shares[i].Scope < nc.Shares[j].Scope })
	for _, s := range nc.Shares {
		nc.Commands = append(nc.Commands, devPullShareCommand(tgtName, ws, ds, s))
	}
	for _, t := range nc.Tokens {
		if cmd := devPullTokenCommand(tgtName, ws, project, t); cmd != "" {
			nc.Commands = append(nc.Commands, cmd)
		}
	}
	return nc
}

// devPullShareCommand is the `bp share add` line that recreates one share.
func devPullShareCommand(tgtName, ws, ds string, s devPullShare) string {
	project := s.Project
	if project == "" {
		project = "default"
	}
	access := s.Access
	if access == "" {
		access = "read"
	}
	return fmt.Sprintf("bp -s %s share add %s %s --access %s --yes",
		shellWord(tgtName), shellWord(ws+"/"+project+"/"+ds), shellWord(strings.Join(s.Surfaces, ",")), shellWord(access))
}

// devPullTokenCommand is the `bp token create` line that mints a token with the
// same label, permissions and dataset binding. A token of another kind (a
// ticket key) has no such command and returns "": the summary lists it so the
// person can recreate it where it was made.
func devPullTokenCommand(tgtName, ws, project string, t devPullToken) string {
	if t.Kind != "" && t.Kind != "api" {
		return ""
	}
	perms := strings.Join(t.Permissions, ",")
	if perms == "" {
		perms = "read"
	}
	cmd := fmt.Sprintf("bp -s %s -w %s -p %s token create %s --permissions %s",
		shellWord(tgtName), shellWord(ws), shellWord(project), shellWord(t.Label), shellWord(perms))
	if t.Dataset != "" {
		cmd += " --dataset " + shellWord(t.Dataset)
	}
	return cmd + " --yes"
}

// devPullGetJSON sends one authenticated GET and decodes a 2xx JSON body.
func devPullGetJSON(client *http.Client, u, token string, into any) error {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := readCapped(resp.Body, maxResponseBytes)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		ae := classifyErrorWithHeader(resp.StatusCode, body, resp.Header)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, ae.errorMessage())
	}
	if err := json.Unmarshal(body, into); err != nil {
		return fmt.Errorf("unreadable answer: %v", err)
	}
	return nil
}

// shellWord quotes s for a POSIX shell when it holds anything beyond a safe
// set, so a printed command can be pasted as is.
func shellWord(s string) string {
	if s == "" {
		return "''"
	}
	safe := true
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case strings.ContainsRune("-_./,:=@+", r):
		default:
			safe = false
		}
		if !safe {
			break
		}
	}
	if safe {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
