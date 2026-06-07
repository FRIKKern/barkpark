package setup

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// knownPlugins is the curated fallback set of selectable plugin slugs when
// on-disk discovery is not practical (e.g. the user is running `bp setup` from a
// release binary with no checkout alongside it). It mirrors the bundled plugin
// brands documented in the repo. Disk discovery, when it finds anything, is
// unioned with this list so a newly-added plugin dir shows up without a code
// change here.
var knownPlugins = []string{"bulldocs", "onixedit", "frt", "indx"}

// pluginSearchDirs are the candidate locations of the plugin schema tree,
// relative to the working directory. DiscoverPlugins walks up from cwd looking
// for the first one that exists, so `bp setup` finds the plugins whether it is
// invoked from the repo root or from a subdirectory.
var pluginSearchDirs = []string{
	"api/priv/plugins",
	"priv/plugins",
}

// DiscoverPlugins returns the selectable plugin slugs. It tries to read the
// on-disk plugin tree (api/priv/plugins/*) from the nearest ancestor of cwd that
// has one; on success it unions the discovered slugs with knownPlugins so the
// curated brands (e.g. indx, which has no priv/plugins schema dir) are always
// offered. When no tree is found it falls back to knownPlugins verbatim. The
// result is de-duplicated and sorted for a stable UX.
func DiscoverPlugins() []string {
	found := discoverFromDisk()
	set := map[string]bool{}
	for _, p := range knownPlugins {
		set[p] = true
	}
	for _, p := range found {
		set[p] = true
	}
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// discoverFromDisk walks up from cwd (bounded) looking for a plugin schema tree
// and returns the immediate child directory names (each is a plugin slug). It
// skips the "media" dir — media is core infrastructure, not an operator-toggled
// plugin in the BARKPARK_PLUGINS sense. An empty result means "nothing found",
// and the caller falls back to the known list.
func discoverFromDisk() []string {
	dir, err := os.Getwd()
	if err != nil {
		return nil
	}
	for i := 0; i < 8; i++ { // bounded walk-up
		for _, rel := range pluginSearchDirs {
			cand := filepath.Join(dir, rel)
			entries, derr := os.ReadDir(cand)
			if derr != nil {
				continue
			}
			var slugs []string
			for _, e := range entries {
				if !e.IsDir() {
					continue
				}
				name := e.Name()
				if name == "media" || strings.HasPrefix(name, ".") {
					continue
				}
				slugs = append(slugs, name)
			}
			if len(slugs) > 0 {
				return slugs
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return nil
}

// PluginsEnvValue maps a chosen plugin selection onto the BARKPARK_PLUGINS env
// value, exactly honouring the kill-switch semantics of
// Barkpark.Plugins.EnvConfig.parse/1:
//
//   - selected == nil          -> ("", false): UNSET. The caller must NOT emit a
//     BARKPARK_PLUGINS line at all, so the registry discovers every plugin from
//     disk. This is the "default: all bundled" / fresh-install semantics.
//   - selected == []           -> ("", true):  the explicit kill switch. Emit
//     BARKPARK_PLUGINS= (empty) to register NO plugins.
//   - selected == ["a","b"]    -> ("a,b", true): whitelist mode.
//
// The bool return ("set") tells the caller whether to emit the env line at all.
// Trimming + blank-dropping mirrors the Elixir parser so the round-trip is
// faithful.
func PluginsEnvValue(selected []string) (value string, set bool) {
	if selected == nil {
		return "", false
	}
	cleaned := make([]string, 0, len(selected))
	for _, p := range selected {
		p = strings.TrimSpace(p)
		if p != "" {
			cleaned = append(cleaned, p)
		}
	}
	return strings.Join(cleaned, ","), true
}

// PluginsSummary renders a one-line human description of a plugin selection for
// dry-run / confirm screens. It makes the all-vs-subset-vs-none distinction
// explicit so the operator is never surprised by the kill-switch default.
func PluginsSummary(selected []string) string {
	value, set := PluginsEnvValue(selected)
	switch {
	case !set:
		return "all bundled (BARKPARK_PLUGINS unset — registry discovers every plugin)"
	case value == "":
		return "NONE (BARKPARK_PLUGINS= — kill switch, no plugins registered)"
	default:
		return value + " (BARKPARK_PLUGINS=" + value + " — whitelist)"
	}
}
