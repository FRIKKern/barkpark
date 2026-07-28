# v11 — the record.test.mjs vacuous-green claim, re-derived at origin/main a9638ecef

Verifier `v11-record-test-vacuous-green`, wave 11 (2026-07-28). Tree: primary checkout
`/Volumes/SATECHI/github/barkpark`, HEAD `a9638ecefb3e98df6c7343455dde31553367229d` == `origin/main`,
node **v22.22.0**. Every count below is taken in a git repo (D82(a): outside one the suite lies).

| # | claim | rerun | observed | level |
|---|---|---|---|---|
| 1 | `tooling/grip/test/record.test.mjs` does NOT exist on origin/main | `git ls-tree --name-only origin/main tooling/grip/test/ \| grep -c record` | `0`; the dir holds **17** files, none named `record` | L2 |
| 2 | A missing file **alone** is a HARD ERROR, exit 1 — the filed claim "exits 0 with # fail 0" is FALSE in this shape | `node --test tooling/grip/test/record.test.mjs; echo $?` | `Could not find 'tooling/grip/test/record.test.mjs'` / `1` | L1 |
| 3 | A missing file **alongside a green one** is silently skipped, exit 0, `# fail 0`, and no line names it | `node --test tooling/grip/test/level.test.mjs tooling/grip/test/record.test.mjs; echo $?` | `# tests 71 / # pass 71 / # fail 0 / # skipped 0`, `EXIT=0` | L1 |
| 4 | A node-expanded glob matching NOTHING is a silent zero-test green (third shape; charter D113 names it, README does not demo it) | `node --test 'tooling/grip/test/record*.test.mjs'; echo $?` | `1..0 / # tests 0 / # fail 0 / # duration_ms 5.83`, `EXIT=0` | L1 |
| 5 | The bare-DIRECTORY form is a hard red, not a discovery walk (D82(b)) | `node --test tooling/grip/test/; echo $?` | `# tests 1 / # fail 1`, `ERR_TEST_FAILURE`, `EXIT=1` | L1 |
| 6 | README.md:177-183's own worked example NO LONGER REPRODUCES — it prints `# tests 60 / # pass 60 / # fail 0 / EXIT=0`; the file is now 77 tests and RED on main | `node --test tooling/grip/test/ledger.test.mjs tooling/grip/test/DOES-NOT-EXIST.test.mjs; echo $?` | `not ok 77 - CONTROL: the committed rows fold CLEAN…` / `# tests 77 / # pass 76 / # fail 1`, `EXIT=1` | L1 |
| 7 | `admitFact` has no dedicated suite; incidental coverage only | `grep -rl admitFact tooling/grip/test/` then `grep -c` each | `adjudicate.test.mjs` **5**, `level.test.mjs` **17**; no other test file | L2 |
| 8 | NO gate, task or workflow names `record.test.mjs`; the only tracked mention is the README saying it is absent | `git grep -n 'record\.test' origin/main -- .` | 2 hits, both `tooling/grip/README.md:191-192` | L2 |
| 9 | Module/test parity is 16 modules vs **17** test files (not 16/16): 3 modules untested (`cli`, `harvest`, `record`), 4 test files with no module (`class-coverage`, `fanout-floors`, `inloop-gate`, `wiring`) | `git ls-tree --name-only origin/main tooling/grip/ \| grep -c '\.mjs$'` + per-name `git cat-file -e` loop | `16` / `17`; 3 NO-TEST, 4 NO-MODULE | L2 |
| 10 | An open published row ALREADY owns this: `tgw10-bl-record-mjs-untested`, parent `truth-grip-epic`, priority 2, 0/5, issue #6355 | `bp task get tgw10-bl-record-mjs-untested -o json` | `"lifecycle_status":"open"`, `"parent_id":"truth-grip-epic"`, `criteria_progress {met:0,total:5}` | L2 |

**Ruling.** Half one of the inherited claim is CONFIRMED (the file is absent). Half two is
**REFUTED as filed** and confirmed only in the multi-arg shape. The imprecise wording is live in a
closed epic row — `tgw5-bl-acceptance-suite-rescope`, "ALSO IN SCOPE: node --test &lt;missing-file&gt;
exits 0 with a clean '# fail 0'" — which is exactly the imprecision README.md:163-164 warns about by
name. The precise version already exists in the done row `tgw5-write-path-docs`.

**The vacuous green is a documented HAZARD, never a realized one:** no artifact anywhere in the
tracked tree cites a `record.test.mjs` pass (row 8). No new task is warranted — row 10 exists; its
digits (16/16 parity, "three test files", expected-file floor 16) are STALE and should read 16/17,
four, and 17.
