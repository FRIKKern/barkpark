package manifest

import "sort"

// Tree is the noun -> verb command tree the CLI walks for dispatch, help, and
// completion. It is built PURELY from a Manifest's Nouns and Commands — the
// package contains zero hardcoded noun or verb names, so a plugin that adds a
// new noun/command appears in the tree with no code change here.
type Tree struct {
	// Nouns are the tree's top-level nodes, in manifest declaration order.
	Nouns []*TreeNoun
	// byNoun indexes Nouns by name for O(1) Lookup.
	byNoun map[string]*TreeNoun
}

// TreeNoun is one noun node holding its verb-leaf commands.
type TreeNoun struct {
	Name    string
	Summary string
	Plugin  *string
	// Verbs are the commands under this noun, in manifest declaration order.
	Verbs []*Command
	// byVerb indexes Verbs by verb token for O(1) Lookup.
	byVerb map[string]*Command
}

// Tree builds the noun->verb tree from m. Noun nodes come from m.Nouns (so a
// noun with zero commands still appears); commands are attached to their noun by
// matching Command.Noun against Noun.Name. A command whose noun is not declared
// in m.Nouns still gets a synthesized node — the manifest is the sole source of
// truth, and dropping such a command would silently hide a capability.
func (m *Manifest) Tree() *Tree {
	t := &Tree{byNoun: make(map[string]*TreeNoun)}

	add := func(name, summary string, plugin *string) *TreeNoun {
		if n, ok := t.byNoun[name]; ok {
			return n
		}
		n := &TreeNoun{
			Name:    name,
			Summary: summary,
			Plugin:  plugin,
			byVerb:  make(map[string]*Command),
		}
		t.byNoun[name] = n
		t.Nouns = append(t.Nouns, n)
		return n
	}

	// Declared nouns first, preserving manifest order.
	for i := range m.Nouns {
		n := m.Nouns[i]
		add(n.Name, n.Summary, n.Plugin)
	}

	// Attach commands; synthesize a noun node for any command whose noun was
	// not declared in m.Nouns.
	for i := range m.Commands {
		cmd := &m.Commands[i]
		node := add(cmd.Noun, "", nil)
		if _, dup := node.byVerb[cmd.Verb]; dup {
			continue
		}
		node.byVerb[cmd.Verb] = cmd
		node.Verbs = append(node.Verbs, cmd)
	}

	return t
}

// Lookup returns the command at (noun, verb), or false if absent.
func (t *Tree) Lookup(noun, verb string) (*Command, bool) {
	n, ok := t.byNoun[noun]
	if !ok {
		return nil, false
	}
	cmd, ok := n.byVerb[verb]
	return cmd, ok
}

// NounNames returns the tree's noun names sorted alphabetically — a stable view
// for help/completion output independent of manifest declaration order.
func (t *Tree) NounNames() []string {
	names := make([]string, 0, len(t.Nouns))
	for _, n := range t.Nouns {
		names = append(names, n.Name)
	}
	sort.Strings(names)
	return names
}
