package cli

// cutAtEndOfFlags splits tail at the first "--": the arguments before it, and
// every argument after it, which are positional however they look. "--" itself
// is dropped. Without one, all of tail comes back first and nothing after.
//
// A task title may start with "--" ("--perspective"), and the may-have-landed
// hint pastes it as `-- '<title>'` (task-379127ebdf341017).
func cutAtEndOfFlags(tail []string) (flagsAndArgs, positional []string) {
	for i, a := range tail {
		if a == "--" {
			return tail[:i], tail[i+1:]
		}
	}
	return tail, nil
}
