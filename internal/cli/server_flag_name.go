package cli

import (
	"strings"
)

// server_flag_name.go — `-s <value>` that is neither a saved server nor a URL.
//
// `-s` takes a saved server's name OR a server URL. A value that matched no
// saved entry used to be used as a raw URL, so a mistyped name (`bp -s nosuch
// doc ls post`) or a bare hostname (`bp -s guerrilla.barkpark.cloud …`) never
// said "no such server": it printed the withheld-credential notice ("was NOT
// sent to nosuch — bp is using the dev default instead") and then a manifest
// transport error, `unsupported protocol scheme ""`, exit 1 (stranger walk,
// 2026-10-01). `bp use nosuch` answers the same typo with a clean not_found
// listing the known names; `-s` now does too.
//
// Only a value WITHOUT a scheme is refused — anything carrying "://" is a URL
// and resolves exactly as before, and so does every saved name, id or URL
// FindServer already matches. Refused before any request, so no credential is
// ever withheld or sent on the typo's account.
func refuseUnknownServerName(out *writer, g globals) (int, bool) {
	q := strings.TrimSpace(g.server)
	if q == "" || strings.Contains(q, "://") {
		return 0, false
	}
	var cfg *Config
	if c, err := LoadConfig(); err == nil {
		cfg = c
	}
	if _, ok := cfg.FindServer(q); ok {
		return 0, false
	}
	names := knownNames(cfg)
	hint := "a server URL needs its scheme: -s https://" + q + " (or http:// for a local server)"
	m := map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    "not_found",
			"message": "no known server matches " + q,
			"hint":    hint,
			"known":   names,
		},
	}
	if out.emitStructured(m) {
		return exitUsage, true
	}
	out.userErr("no known server matches %q", q)
	if len(names) > 0 {
		out.errf("known servers: %s", joinComma(names))
	} else {
		out.errf("no saved servers yet — run 'bp setup --target connect --server <url>'")
	}
	out.errf("%s", hint)
	return exitUsage, true
}
