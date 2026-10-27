package cli

// instance_check_studio.go is `bp instance check --studio-url <url>`: the
// instance settings a Studio with STUDIO_SIGN_IN=sso needs (task-24367).
//
// The Studio starts sign-in at /v1/auth/oidc/<org>/start with
// return_to=<studio origin>/auth/cloud/callback. Barkpark's OIDC controller
// refuses the start with 400 unless that origin is in
// BARKPARK_STUDIO_SSO_ORIGINS, compared as scheme://host[:port] with no
// default port. The identity provider sends the editor back to
// https://PHX_HOST/v1/auth/oidc/<org>/callback, so PHX_HOST and PHX_SCHEME
// decide the redirect URI the app registration must list.

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

const instanceDocStudio = "docs/setup/SELF-HOST.md#sign-in-with-entra-id"

// instanceStudioOrigin returns the origin Barkpark compares for a Studio URL,
// as the browser and the OIDC controller form it.
func instanceStudioOrigin(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil {
		return "", fmt.Errorf("--studio-url is %q; give the Studio's address, such as https://studio.example.com", raw)
	}
	origin := strings.ToLower(u.Scheme) + "://" + strings.ToLower(u.Hostname())
	if p := u.Port(); p != "" && !(u.Scheme == "https" && p == "443") && !(u.Scheme == "http" && p == "80") {
		origin += ":" + p
	}
	return origin, nil
}

func instanceStudioLoopback(origin string) bool {
	u, _ := url.Parse(origin)
	h := u.Hostname()
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// instanceStudioCheck compares the instance's Studio settings with studioURL.
func instanceStudioCheck(env map[string]string, studioURL string) (problems, notes []instanceProblem) {
	origin, err := instanceStudioOrigin(studioURL)
	if err != nil {
		return []instanceProblem{{Setting: "BARKPARK_STUDIO_SSO_ORIGINS", Problem: err.Error(), Doc: instanceDocStudio}}, nil
	}
	const name = "BARKPARK_STUDIO_SSO_ORIGINS"
	add := func(format string, a ...any) {
		problems = append(problems, instanceProblem{Setting: name, Problem: fmt.Sprintf(format, a...), Doc: instanceDocStudio})
	}
	raw := strings.TrimSpace(env[name])
	var listed []string
	found := false
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		listed = append(listed, entry)
		if entry == origin {
			found = true
			continue
		}
		// An entry with a path, a trailing slash, a default port or capitals
		// never equals an origin, so the start refuses that Studio.
		if norm, err := instanceStudioOrigin(entry); err == nil && norm != entry {
			add("%s lists %q, which never matches because Barkpark compares bare origins. Write %s.", name, entry, norm)
		}
	}
	switch {
	case isPlaceholder(raw):
		add("%s still holds a placeholder. Set it to %s.", name, origin)
	case len(listed) == 0:
		add("%s is not set, so the sign-in start refuses the Studio's return_to with 400 and the Studio's single sign-on button fails. Set it to %s.", name, origin)
	case !found:
		add("%s is %s and does not list %s, so the sign-in start refuses that Studio with 400. Add %s.", name, raw, origin, origin)
	}
	if !found && strings.Contains(","+strings.ReplaceAll(env["BARKPARK_ALWAYS_ALLOWED_ORIGINS"], " ", "")+",", ","+origin+",") {
		notes = append(notes, instanceProblem{Setting: name, Doc: instanceDocStudio, Problem: fmt.Sprintf(
			"%s is in BARKPARK_ALWAYS_ALLOWED_ORIGINS. That list is for browser calls; the Studio calls Barkpark from its server, and sign-in reads only %s.", origin, name)})
	}
	if strings.HasPrefix(origin, "http://") && !instanceStudioLoopback(origin) {
		add("%s is plain HTTP on a host other than this machine, so the sign-in ticket would cross the network unencrypted. Serve the Studio over HTTPS.", origin)
	}

	host := env["PHX_HOST"]
	if host == "" || isPlaceholder(host) {
		host = "<host>"
	}
	scheme := orDefault(env["PHX_SCHEME"], "https")
	notes = append(notes, instanceProblem{Setting: name, Doc: instanceDocStudio, Problem: fmt.Sprintf(
		"the Studio at %s receives sign-ins at %s/auth/cloud/callback. Its STUDIO_SIGN_IN=sso and STUDIO_SSO_ORG=<org> start at %s://%s/v1/auth/oidc/<org>/start, and the identity provider's redirect URI must be %s://%s/v1/auth/oidc/<org>/callback.",
		origin, origin, scheme, host, scheme, host)})
	return problems, notes
}
