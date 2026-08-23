---
"@barkpark/codegen": patch
---

Generated output no longer depends on the process CWD: the prettier config is resolved against the OUTPUT file's path (the generated file is formatted like its committed siblings), and with no output path there is no config search at all — prettier defaults, byte-stable from any directory. Previously `resolveConfig(process.cwd())` started the search in the cwd's parent, so running `barkpark generate` from different directories emitted different bytes (the whole diff was semicolons).
