# CLOSE PACKET - pr-10129 (11 rows) + ledger-reclamation (6 rows)

Criteria re-fetched fresh per row via `bp task get <id> -o json` on 2026-08-22 (post your disposition fixes); stored text at `.doc.content.acceptance_criteria`. Every row is 0/N met, so EVERY zero-based index below is unmet. Exact stored text: one file per criterion in this directory, `<row>__crit<N>.txt` - byte counts and sha256 (full) below; nothing inline.

Measurement base: origin/main @ aabaf83ca2 (fetched); gh PR states read 2026-08-22. Re-land checks done per your correction: #10720->#12737 and #10811->#12738 independently re-verified (both MERGED 2026-08-20, symbols live).

## Chain: pr-10129

### dr-w11-bl-10129-ladder-arithmetic
- **verdict: ALREADY-DONE** (confidence tier A)
- unmet criteria (zero-based): [0] - all 1 unmet
  - crit0: `packet/dr-w11-bl-10129-ladder-arithmetic__crit0.txt` - 178 bytes, sha256 `796099c4a420b07e2583867a3ce1eda6216be1c5a7d869b1684f83e0b8e2082d`
- proof: The row closes by its OWN criterion terms ("a landed charter decision"): the arithmetic IS decided and landed - D202 fixes deploys_failing=5 (charter:4059,:4493) and D224 rules unmetered at rank 9 within the thirteen-rung shape (charter:4489). Both on origin/main @ aabaf83ca2.

### dr-w17-bl-close-and-recut-10129
- **verdict: SUPERSEDED** (confidence tier A)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w17-bl-close-and-recut-10129__crit0.txt` - 141 bytes, sha256 `67dccb1e23da52b65e3884213668d0eafa14e6d7c803f2a7cbfc35f5998236ea`
  - crit1: `packet/dr-w17-bl-close-and-recut-10129__crit1.txt` - 219 bytes, sha256 `4deeb7dca5807a4fc197f258cf66b5195d77b5574c058d9465167dd18e6339e5`
  - crit2: `packet/dr-w17-bl-close-and-recut-10129__crit2.txt` - 224 bytes, sha256 `d221c19a8bfe0be207399ca1a424f7215643e9989d690de85a0162839efd063d`
- proof: crit0: #10129 IS CLOSED with a capability-superseded comment (2026-08-19T23:33:07Z: "DeployLedger.census/rate/parse_window/list_page all exist"). crit1: the four corrections LANDED, not just filed - live_rate = live/volume through rate/2 (cloud/lib/barkpark_cloud/deploy_ledger.ex:1098, D229 at :115), charter:5727 records "D185/D202/D224; re-cut on volume, emitting live, with the rung reading absorption". crit2: the ladder-drift row exists (dr-w19-bl-collapse-the-four-spa-ladder-rows, open in this shard).

### dr-w23-bl-rebase-10129-after-10720
- **verdict: SUPERSEDED** (confidence tier A)
- unmet criteria (zero-based): [0, 1, 2, 3] - all 4 unmet
  - crit0: `packet/dr-w23-bl-rebase-10129-after-10720__crit0.txt` - 87 bytes, sha256 `79fadbb3ba7c7db41bed7b2e533f2c8e32307072bcfa26cea98225777f54f784`
  - crit1: `packet/dr-w23-bl-rebase-10129-after-10720__crit1.txt` - 152 bytes, sha256 `c92f39dde03114ca1196db90790b20265f83ecd98f7cb12c1b1289275e064853`
  - crit2: `packet/dr-w23-bl-rebase-10129-after-10720__crit2.txt` - 117 bytes, sha256 `c093a3310e66c74d121bef58156b609f1961f36c035425e5fd9973f70d234b9f`
  - crit3: `packet/dr-w23-bl-rebase-10129-after-10720__crit3.txt` - 139 bytes, sha256 `bf9967b65b3d5255758511d739844cceb876b9224efc384fe27f07fde8d97419`
- proof: Both halves of the ordering premise dissolved. #10720 re-landed as #12737 (MERGED 2026-08-20T08:37:11Z; commitCell live at internal/cli/cloud_status_cmd.go:444, read at :982). #10129 rebase is ruled OFF by charter: D185 "#10129 IS NOT REBASED" (charter:3719), D242 "#10129 GO ARM DOES NOT REBASE" (charter:4756), and #10129 is CLOSED with a superseded-comment (2026-08-19T23:33:07Z). Do NOT close as a twin - close citing the ruling + the re-land.

### dr-w26-bl-10129-and-10086-red-mains-census-on-merge
- **verdict: MOOT** (confidence tier A)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w26-bl-10129-and-10086-red-mains-census-on-merge__crit0.txt` - 160 bytes, sha256 `e451719f88922c09203d404b24b7325cc36f7eff355eb6f3bb681c2bc1558bdb`
  - crit1: `packet/dr-w26-bl-10129-and-10086-red-mains-census-on-merge__crit1.txt` - 125 bytes, sha256 `168f131fa73697543078be1114097b38e35b87a2c4a4cd5ac30e7ad4fa6e5f97`
  - crit2: `packet/dr-w26-bl-10129-and-10086-red-mains-census-on-merge__crit2.txt` - 137 bytes, sha256 `7ada6ff3dae37806977b79f3665f90c4e4f78dbf32f7c411390a9d11892bbe78`
- proof: Premise = two OPEN PRs frozen-green that will red main ON MERGE. Both are CLOSED, mergedAt null (gh-verified 2026-08-22): they can never merge, never red main, and crit 0/1 (rebase them, re-fire their checks) are unsatisfiable on closed PRs. Residue worth 1 line: crit 2 generic decision (re-fire stale checks on path-set widening) - re-file only if wanted.

### dr-w33-bl-10811-reds-mains-census-on-merge
- **verdict: SUPERSEDED** (confidence tier A)
- unmet criteria (zero-based): [0, 1, 2, 3, 4] - all 5 unmet
  - crit0: `packet/dr-w33-bl-10811-reds-mains-census-on-merge__crit0.txt` - 211 bytes, sha256 `43e41f699a05b74761786e679700dbd9be028532fa41f11a9ae5c9f586649dfe`
  - crit1: `packet/dr-w33-bl-10811-reds-mains-census-on-merge__crit1.txt` - 223 bytes, sha256 `020f60ce79ddbad1f699edf2531ec0e991b3e2c9e38cf49a599a72e12fecf31d`
  - crit2: `packet/dr-w33-bl-10811-reds-mains-census-on-merge__crit2.txt` - 167 bytes, sha256 `bd06ec0bcda726933b499cacd17215149bdd3d1c54a3ae22ff86c4a927b347bb`
  - crit3: `packet/dr-w33-bl-10811-reds-mains-census-on-merge__crit3.txt` - 225 bytes, sha256 `70232caf32235e480cbfbdcc6e9b522ca3337ba56fd46638ead974abf9a2d3f2`
  - crit4: `packet/dr-w33-bl-10811-reds-mains-census-on-merge__crit4.txt` - 161 bytes, sha256 `19d288bcbfe9430be4f4723cfcb705148c3e0d335594e68d7d18706a874f5687`
- proof: #10811 re-landed as #12738 (MERGED 2026-08-20T08:46:33Z, gh-verified). PROOF: coalesced_attempts decoded in internal/cli/cloud_deploy_census_cmd.go:592,:614 (charter D547 recorded the symbol ABSENT from internal/ before the re-land = measured state change); the crit-1 co-edit shipped WITH it - payload_key_set_census_test.exs:1282-1295 documents the six new json tags + the DELETE-the-allowlist-row arm executed, floors asserted with == at :1274/:1341. Every criterion is about rebasing the dead PR number; the capability is on main.

### dr-w13-bl-10129-window-is-pinned-by-nothing
- **verdict: SUPERSEDED** (confidence tier B)
- unmet criteria (zero-based): [0, 1, 2, 3] - all 4 unmet
  - crit0: `packet/dr-w13-bl-10129-window-is-pinned-by-nothing__crit0.txt` - 152 bytes, sha256 `70cf0b3ad6d825bbdef2040d5a190a43a24fa674bf1f9fcbb0bf078011cace0d`
  - crit1: `packet/dr-w13-bl-10129-window-is-pinned-by-nothing__crit1.txt` - 91 bytes, sha256 `55ac4056c559086e55a48fcf8c4f2d0cd6be9363be1775975c0a03189f7b3f8d`
  - crit2: `packet/dr-w13-bl-10129-window-is-pinned-by-nothing__crit2.txt` - 125 bytes, sha256 `e69030072a362080dfb878abcaed72010cb4172a3f74c8b6b8c62fef0a9eeecc`
  - crit3: `packet/dr-w13-bl-10129-window-is-pinned-by-nothing__crit3.txt` - 98 bytes, sha256 `34d9eba01d1efc0465ca7a2b45553c1648a2ebe75093899b74b314f9a706621f`
- proof: Split verdict, split proof. WINDOW half landed under different names: the census runs over a PINNED inserted_at window with as_of = the window's to, never utc_now (deploy_ledger.ex:74,:1071,:1351; deploy_ledger_test.exs pinned-edge tests e.g. :3154). LADDER half (deployMarker rung, rank-5, semrole union) folds into the surviving decision row dr-w24-bl-129-ladder-decision-is-owed - deploys_failing is measured ABSENT from internal/cli today.

### dr-w15-bl-10129-ladder-is-a-redo
- **verdict: SUPERSEDED** (confidence tier B)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w15-bl-10129-ladder-is-a-redo__crit0.txt` - 151 bytes, sha256 `c168f421544d6a7ec3168d3b9024852d946929791aab5df54c0b059ee44833cc`
  - crit1: `packet/dr-w15-bl-10129-ladder-is-a-redo__crit1.txt` - 117 bytes, sha256 `7bf01b53f89835385dc0aa97afe81f8735d09e2b575f33ab6155a8f7748daa95`
  - crit2: `packet/dr-w15-bl-10129-ladder-is-a-redo__crit2.txt` - 120 bytes, sha256 `df4766c534514151cab7f1439c64645aa5793d6eebc18f818370e6cd5d61aa23`
- proof: crit1's second arm executed: "#10129 is closed with the reason recorded" - closed 2026-08-19T23:33 with the superseded comment. crit0 (charter decision recording the MERGED ladder) is the SAME decision dr-w24-bl-129-ladder-decision-is-owed survives to carry. Successor: dr-w24-bl-129-ladder-decision-is-owed.

### dr-w20-bl-open-pr-disposition-10129-10086-10400-10019
- **verdict: SUPERSEDED** (confidence tier B)
- unmet criteria (zero-based): [0, 1, 2, 3, 4] - all 5 unmet
  - crit0: `packet/dr-w20-bl-open-pr-disposition-10129-10086-10400-10019__crit0.txt` - 140 bytes, sha256 `c5343e4688ab435dfae3393cdda4e893290209c9430dafcd9387cb8c561eba6f`
  - crit1: `packet/dr-w20-bl-open-pr-disposition-10129-10086-10400-10019__crit1.txt` - 194 bytes, sha256 `eab9972150e8858d735026d34e733aab83108f77b89295dd1cb59a797d4efec0`
  - crit2: `packet/dr-w20-bl-open-pr-disposition-10129-10086-10400-10019__crit2.txt` - 143 bytes, sha256 `d75661e9a204822ba0bc74cafbcc965158af7e471e7161993a6e993700ef949a`
  - crit3: `packet/dr-w20-bl-open-pr-disposition-10129-10086-10400-10019__crit3.txt` - 70 bytes, sha256 `84e94c853c702a7d724d64a64ea21cfb70bbfcaf340c977c0cd1bb7a45e651d9`
  - crit4: `packet/dr-w20-bl-open-pr-disposition-10129-10086-10400-10019__crit4.txt` - 157 bytes, sha256 `00ffc7e8cf8760a8fded949b362ee78a0b094dd3cb08ccb8fda5126edd689c63`
- proof: Successor: dr-w32-bl-close-10400-park-10129-merge-10811 - the LATER lead ruling REVERSED this row's crit1 ("#10400 is rebased" -> "close #10400") and the reversal was executed: all four PRs CLOSED, mergedAt null (gh-verified). The surviving-value item (box_rates/3 as its own row) exists: dr-w10-s1-followup-box-rates-query-cost is open in this shard.

### dr-w32-bl-close-10400-park-10129-merge-10811
- **verdict: SUPERSEDED** (confidence tier C)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w32-bl-close-10400-park-10129-merge-10811__crit0.txt` - 175 bytes, sha256 `d287f7cc1780720e03f7ca177002de45475e33c64040c6db6882081420770595`
  - crit1: `packet/dr-w32-bl-close-10400-park-10129-merge-10811__crit1.txt` - 135 bytes, sha256 `46bc39d85ca00fad93981c97e79bea3768bd65c1e0b86b612d552bc80e772f9c`
  - crit2: `packet/dr-w32-bl-close-10400-park-10129-merge-10811__crit2.txt` - 155 bytes, sha256 `4119f7327ded4237136b40cd00f9b31dd84b4caa3a23eb9dbd8b585d6e7af3c6`
- proof: All three acts executed in substance: #10400 CLOSED (gh); #10129 dispositioned by ruling (D167/D185 recorded, PR closed with comment - NOTE crit1 as stored says "left open", now unsatisfiable to the letter); #10811 delivered via re-land #12738 MERGED (crit2's "rebased and merged" arm, by successor). ONE RESIDUAL ACT: origin/loop-epic/the-content-api-s-own-status-stops-being-1 still EXISTS (git ls-remote: 9eca36577efb) - crit0's branch deletion was never done. Close the row, carry the one-command branch deletion into the close note or a micro-act.

### dr-w24-bl-129-ladder-decision-is-owed
- **verdict: STILL REAL** (confidence tier KEEP)
- unmet criteria (zero-based): [0] - all 1 unmet
  - crit0: `packet/dr-w24-bl-129-ladder-decision-is-owed__crit0.txt` - 88 bytes, sha256 `7fe9275e83aeb1e8f6c6d3b74a6dd3797577928c1d1f9e90f417b88f9768ad2d`
- proof: THE SURVIVOR of the pr-10129 chain. The ruling D185 owes (deploys_failing rank / is unmetered a rung) is still unmade in final form: internal/cli attentionRankOrder is ELEVEN rungs today (cloud_status_cmd.go:483-495) and deploys_failing appears NOWHERE in internal/cli (grep = 0, self-tested). Coordinator note honored: #10129 is PARKED by D167/D185, head 514ff5c6f6 live - this row records it; do not moot it.

### dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window
- **verdict: STILL REAL** (confidence tier KEEP)
- unmet criteria (zero-based): [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11] - all 12 unmet
  - crit0: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit0.txt` - 207 bytes, sha256 `bbdfa03630f7dbc0e8f48e2decaefbf97737fb5b2d22896ec80dad6a53fbfa5c`
  - crit1: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit1.txt` - 287 bytes, sha256 `4eda72e0f47531a0f58134e50cb6d3e82b4edcfdf05b3b8d014f8a459d8fad18`
  - crit2: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit2.txt` - 261 bytes, sha256 `610838a9b7b3320ffaa9388dff792be09c0f2b1c4f3007735eb90fdd68ba3fa7`
  - crit3: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit3.txt` - 209 bytes, sha256 `1ba14587daeeeb5e351c008752ba7875df3609991d689ff79395d254e9bc987e`
  - crit4: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit4.txt` - 355 bytes, sha256 `c9f6c7213554cfe8c030de35b6d8a9582562516a8c648805a073abedc455ce82`
  - crit5: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit5.txt` - 294 bytes, sha256 `b878c01fd9b295f855354fe5f3e6e480ad8a21fcf0430342a6e2fb34432e01bf`
  - crit6: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit6.txt` - 365 bytes, sha256 `9c8cbb1d9d7f387dbab156e54c01d55ba50ad5f9fef058adbf735439e78a7291`
  - crit7: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit7.txt` - 313 bytes, sha256 `72aa88b73630598ab94ca3b0ed343f960c4dcdea22a06917faca26f019689996`
  - crit8: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit8.txt` - 308 bytes, sha256 `6ec3200684a3c7ac88dc649cbed86de8a97cd2e652d40c01d460a24716d0d5e2`
  - crit9: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit9.txt` - 187 bytes, sha256 `0ed2b648cf69f76693bd8581225b74e14194d19097fc6d73c11c133e4226df37`
  - crit10: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit10.txt` - 232 bytes, sha256 `a73a37467560710a6b5336eb673d675a2814a4080dd28cea39986247563dce1c`
  - crit11: `packet/dr-w14-s5-fleet-deploy-arm-lands-with-a-pinned-window__crit11.txt` - 120 bytes, sha256 `a34dfc8a892f0ab31041145e7c0dad6bd30535e1415dbb7c83a683c3ea333c57`
- proof: The CAPABILITY is still absent: no thirteen-rung ladder, no deploys_failing in internal/cli (measured today). But UNBUILDABLE AS WRITTEN - crit0 demands rebasing the now-closed #10129; crit11 already allows "or its successor PR". Needs a re-cut AFTER the dr-w24-bl-129-ladder-decision-is-owed ruling; sequence it behind that row.

## Chain: ledger-reclamation

### dr-w22-bl-epic-ledger-abandonment-269-never-started
- **verdict: SUPERSEDED** (confidence tier B)
- unmet criteria (zero-based): [0, 1, 2, 3] - all 4 unmet
  - crit0: `packet/dr-w22-bl-epic-ledger-abandonment-269-never-started__crit0.txt` - 74 bytes, sha256 `d37aed737610ffa44f61e0e3533e1c4816e1b435872db326c13ded0b45c87db2`
  - crit1: `packet/dr-w22-bl-epic-ledger-abandonment-269-never-started__crit1.txt` - 95 bytes, sha256 `35fc2ea0d9b30129015a081b05cd33163b2f9579c856850d3dedbf0999fdde04`
  - crit2: `packet/dr-w22-bl-epic-ledger-abandonment-269-never-started__crit2.txt` - 78 bytes, sha256 `ee5474dfff582214362caba6aef4ac6566faa770a5e75b990e35c05f4f2f5239`
  - crit3: `packet/dr-w22-bl-epic-ledger-abandonment-269-never-started__crit3.txt` - 116 bytes, sha256 `805b970dca116b35f4fba9187f94bbc45b8c5665089b635aeeee0d8bfd66d43b`
- proof: crit3 (the big one) executed at scale: 333 rows are now parented under dr-backlog-never-started (measured from the 2026-08-22 ls snapshot), each adoption recorded in disposition_reason citing charter S-4c, re-parented NOT bulk-cancelled - exactly what the criterion demanded. crit0-2 are w22-vintage counts (2 drafts / 32 one-short rows) that no longer denote fixed populations; the successor generation is dr-w31-bl-reclaim-the-open-ledger-in-one-act.

### dr-w26-bl-ledger-stale-open-is-not-proof-unstamped
- **verdict: SUPERSEDED** (confidence tier C)
- unmet criteria (zero-based): [0, 1, 2, 3, 4] - all 5 unmet
  - crit0: `packet/dr-w26-bl-ledger-stale-open-is-not-proof-unstamped__crit0.txt` - 135 bytes, sha256 `78340f087fb154264bb4344b92260479b1d745da72a9fe6959840a8763dadd5a`
  - crit1: `packet/dr-w26-bl-ledger-stale-open-is-not-proof-unstamped__crit1.txt` - 121 bytes, sha256 `9b3ed83cd3546c913f9bb03c7a2ae2cf85b5c55deb0fb296b6ea06b4d2844313`
  - crit2: `packet/dr-w26-bl-ledger-stale-open-is-not-proof-unstamped__crit2.txt` - 184 bytes, sha256 `a6ade9f8d1ad345b0d5ed555584173c7f385c7cb76e83053fff270acbb596108`
  - crit3: `packet/dr-w26-bl-ledger-stale-open-is-not-proof-unstamped__crit3.txt` - 66 bytes, sha256 `53a8034e94aa3663a6bd4128b95a5189134e0528f3b74b6742c885fc037275b6`
  - crit4: `packet/dr-w26-bl-ledger-stale-open-is-not-proof-unstamped__crit4.txt` - 139 bytes, sha256 `842ca52d9572604b0e1721516763eeb60d41ea3655d30d8a27c7ed7a73fd942d`
- proof: A counting-generation row: successor dr-w31-bl-reclaim-the-open-ledger-in-one-act + the 2026-08-22 five-chain ruling. Executed piece measured: crit3 - dr-w19-s1-unblock-10518-census-rebase is done 8/8 met (updated 2026-08-20). LIVE RESIDUE: crit2 - dr-w24-bl-emit-commit-distance-on-the-fleet-row is STILL open 0/3, neither rewritten nor blocked; carry that single item, not the row.

### dr-w27-bl-reclaim-26-shipped-but-open-rows
- **verdict: SUPERSEDED** (confidence tier C)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w27-bl-reclaim-26-shipped-but-open-rows__crit0.txt` - 81 bytes, sha256 `46565eac93efed744b5e78eb6dfe23ec85f62e7708ba67c03016fbadcbbc5b72`
  - crit1: `packet/dr-w27-bl-reclaim-26-shipped-but-open-rows__crit1.txt` - 168 bytes, sha256 `6221a4b9fabdec05b95d2f127c61390c9a719d809c7acdf7b80570dc9c9a6eec`
  - crit2: `packet/dr-w27-bl-reclaim-26-shipped-but-open-rows__crit2.txt` - 279 bytes, sha256 `ec9dc141ee70a7fb6fd34e0aecf63867bcd1a064db53927c2b37654ac8f5629a`
- proof: Same disease the 2026-08-22 ruling adjudicated: its "26 shipped-but-open" population was wave-27-vintage and overlaps the five-chain + w31 enumerations. Successor: dr-w31-bl-reclaim-the-open-ledger-in-one-act. Residue worth carrying: crit2 (restate dr-w26-s6's merge criterion to the code-scoped grep) belongs on dr-w26-s6's own row if that row is still open.

### dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted
- **verdict: SUPERSEDED** (confidence tier C)
- unmet criteria (zero-based): [0, 1, 2, 3, 4, 5, 6, 7] - all 8 unmet
  - crit0: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit0.txt` - 87 bytes, sha256 `4082bfe75781d04544fcd7b901adf926872598be2961d360ea93a2a4d0656a84`
  - crit1: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit1.txt` - 104 bytes, sha256 `d1064c831189cf9f4c9486abed71fd8a092524763c7de65f8efd8896f4a5d5cc`
  - crit2: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit2.txt` - 127 bytes, sha256 `f2639a10ee03584e2ade37c4a5caa5fc5c11c08f3d8a8409bb72d97622ecd1a8`
  - crit3: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit3.txt` - 187 bytes, sha256 `03b0632e7765003455aee216640445b5728cc5a0a62fa76442718570b0366eee`
  - crit4: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit4.txt` - 242 bytes, sha256 `2ca11c66db7e2e7fb5bd8526ff5ae5e40fb3e1fc73c70ae309db0008cf4bfb27`
  - crit5: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit5.txt` - 148 bytes, sha256 `43c905225722cad6bd80b46070a5f1019463941e09b1af039abf8d76d9b0d08b`
  - crit6: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit6.txt` - 96 bytes, sha256 `d411444fbdef5d4d3d78d8d2039c9607909d7d77de803e4703b1a6948e2e6ff8`
  - crit7: `packet/dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted__crit7.txt` - 125 bytes, sha256 `1842ca3e56ab7ecb3b38e8c09a073929238fe04656d3a02179b0c80bc544b174`
- proof: LARGELY EXECUTED, measured per criterion: [0] #11007+#11008 CLOSED (gh). [1] #11169 CLOSED with the written reason its criterion allowed (comment 2026-08-09T15:45:07Z "the code half already landed, and the prose half cannot be rebased"). [2] #11174 CLOSED. [3] the four charter PRs CLOSED and D256-D336 decisions present in the landed charter (40 grep hits in bp-deploy-reliability-charter.md). [6] dr-w28-s4-followup-payload-key-census-deferral-wait is done 3/3 met. [7] the six cch PRs untouched by this epic. LIVE RESIDUE: [4] gyldendal packet publish - already carried by dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall + dr-w25-hg-gyldendal-operator-stops-the-transmission; [5] the seven drafts.* discards - unverified from here.

### dr-w31-bl-reclaim-the-open-ledger-in-one-act
- **verdict: STILL REAL** (confidence tier KEEP)
- unmet criteria (zero-based): [0, 1, 2, 3, 4] - all 5 unmet
  - crit0: `packet/dr-w31-bl-reclaim-the-open-ledger-in-one-act__crit0.txt` - 179 bytes, sha256 `16b172d99406ab68fdf625a514c558e202ce17a10b0edebd87ee1b21ae906bfc`
  - crit1: `packet/dr-w31-bl-reclaim-the-open-ledger-in-one-act__crit1.txt` - 140 bytes, sha256 `9a2d379c79ea8558a75864ff0c099721296ce9c6feef055183ac453b2b830217`
  - crit2: `packet/dr-w31-bl-reclaim-the-open-ledger-in-one-act__crit2.txt` - 140 bytes, sha256 `3507b3fa586f6aa5fa0ba556d7faaf9e50f69085df599d41f4a01f863821e23f`
  - crit3: `packet/dr-w31-bl-reclaim-the-open-ledger-in-one-act__crit3.txt` - 182 bytes, sha256 `6973ec047eeb80717bb5fbccdd48ea78a3fffec93d08ca87444157c6cd08717f`
  - crit4: `packet/dr-w31-bl-reclaim-the-open-ledger-in-one-act__crit4.txt` - 186 bytes, sha256 `02d4577b5d29860f85b4c63f89a46b8ec24e52702fed05a3db7d6a1af0377c69`
- proof: The surviving sweep order of the ledger-reclamation chain - but RE-DERIVE its enumeration before executing: crit1 is already partly unsatisfiable as stored (dr-transport-silence-still-exits-zero and dr-seal-run-harness-runs-in-no-ci were CANCELLED 2026-08-09, not "closed with evidence quoted"); crit3's second arm is overtaken (dr-bl-w7-capacity-is-noise-next-to-two-unset-flags closed 4/4 met on 2026-08-22) while its first arm is live (dr-w30-bl-box-busy-deferred-is-a-dead-arm still open 0/3). Match FULL row ids on the re-derivation.

### dr-w32-fu-24-landed-rows-need-eyes
- **verdict: STILL REAL** (confidence tier KEEP)
- unmet criteria (zero-based): [0, 1, 2] - all 3 unmet
  - crit0: `packet/dr-w32-fu-24-landed-rows-need-eyes__crit0.txt` - 189 bytes, sha256 `72992a641eeec0f2882bab29fcef80766982c96abb50b15596a12da3a8d39e6c`
  - crit1: `packet/dr-w32-fu-24-landed-rows-need-eyes__crit1.txt` - 182 bytes, sha256 `d1b45a725e1a42699ebaab4a50b14d337c7587f99c12b9d74a1f5ee930c35fc9`
  - crit2: `packet/dr-w32-fu-24-landed-rows-need-eyes__crit2.txt` - 130 bytes, sha256 `050bf019e906acaab160da3bd3e77d78a81cd9adf694d78a4184dc69de9b4280`
- proof: The COUNTER-ORDER that keeps sweeps honest: 21 GROUP-A rows must not close on merge evidence alone, 3 GROUP-B rows carry merge-checks that fail on main. This is the row that prevents the next generation of the disease - execute it WITH dr-w31-bl-reclaim-the-open-ledger-in-one-act, never after a bulk close.

