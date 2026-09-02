DEFECT 1, frozen. This roster.json is exactly what `d.get('doc', d)` selects: the `doc`
sub-object, which has no `children`. The old pipeline died with KeyError while the shell redirect
still created a zero-line file. Here it is a named refusal that says where `children` actually is.
