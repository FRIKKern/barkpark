# Re-derivation recipes — bp-prior-art-retry (mobile blocks wave, 2026-07-26)

Verifier lane: re-run the prior-art searches that timed out during survey, and settle
what the ledger already RULES on video/asciicast degrade anatomy, on WebView islands,
and on any prior canonical-set derivation. Rows re-derive from a clean checkout + a
live `bp` (guerrilla). A timeout is not an absence — every row below is an outcome.

| # | Claim | Command |
|---|---|---|
| 1 | `bp search` is live again; the 3 mandated queries return results (not timeouts) | `bp search query "pdrender block parity degrade video asciicast" -o json \| head -c 400` · `bp search query "dataviz svg mobile ruling" -o json \| head -c 400` · `bp search query "canonical block type set exclusions" -o json \| head -c 400` |
| 2 | NO paper `pdrender-block-parity` (or 3 slug variants) exists — genuine absence, exit 4 | `for s in pdrender-block-parity papers-pdrender-block-parity pdrender-parity block-parity; do bp paper view "$s" >/dev/null 2>&1; echo "$s=$?"; done` |
| 3 | `t3code-upgrade-reconnect-offline` contains ZERO occurrences of "WebView"/"island"/"KaTeX" — the assignment's premise misattributes the overturned row | `bp paper view t3code-upgrade-reconnect-offline \| grep -ci 'webview\|island\|katex'` |
| 4 | D42's "its WebView row is overturned" refers to the SHELL-AND-CACHE lane paper | `grep -o 'Executable design inherits[^;]*;' .claude/workflows/bp-barkpark-tasks-mobile-charter.md` |
| 5 | The overturned row is the shell paper's `PortableDoc papers` row: "WebView string HTML — inherits 66 types + parity proof" vs "Rebuild ~66 emitters … permanent drift risk" | `bp paper view barkpark-tasks-mobile-shell-and-cache \| sed -n '80,95p'` |
| 6 | Overturned AWAY from WebView by a 2026-07-25 USER RULING standing in for the D11 hardware measurement; islands survive explicitly | `grep -n 'The D11 story, told straight' -A0 .claude/workflows/bp-barkpark-tasks-mobile-charter.md` (charter line 117) and line 116 (`mob-w2-paper-reader`) |
| 7 | Per-diagram WebView islands are RATIFIED in the same ruling; only the FULL-DOCUMENT WebView died ("explicitly NO full-document WebView"); 3.7 MB marginal is the D11 ADVISORY EMULATOR number | `sed -n '116p;95p' .claude/workflows/bp-barkpark-tasks-mobile-charter.md` |
| 8 | The charter records NO per-block-type degrade ruling — every "degrade" hit is StreamStatus (D24) / manifest pickers (D27) / SDK stale-board (s6) | `grep -ni degrade .claude/workflows/bp-barkpark-tasks-mobile-charter.md` |
| 9 | Degrade anatomy for asciicast IS recorded — in Go code with a doctrine comment: "honest, labeled fallbacks … a clearly-LABELED box that states its ceiling — never a fake of a capability it lacks … mirrors render.ex's email-mode degradation" | `git show origin/main:internal/pdrender/hardblocks.go \| sed -n '1,30p'` |
| 10 | asciicast anatomy: bordered box, "▶ Asciicast" + `duration · COLSxROWS` meta + "· open in browser", src as OSC8 link else dim "(src)" | `git show origin/main:internal/pdrender/hardblocks.go \| sed -n '/── asciicast/,/^\/\/ ── image/p'` |
| 11 | video anatomy: "▶ Video" + "· N caption track(s)" + "· open in browser"; poster/loop have no TUI effect; NEVER plays | `git show origin/main:internal/pdrender/video.go` |
| 12 | video's Go renderer returns `nil` on empty `src` while its own comment promises "the honest empty box" — a src-less video fixture renders NOTHING (crown-proof "0 empty" trap) | `git show origin/main:internal/pdrender/video.go \| sed -n '18,27p'` |
| 13 | A per-surface degrade grading exists per-type in the wishlist ledger: video = "TUI: labeled box + path line (media precedent) · Email: degrade badge: poster / link" | `bp task get pbw-stier-video -o json \| python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["content"]["description"])'` |
| 14 | asciicast has NO pbw wishlist task (it is an M2 block, predates the wishlist) | `bp task get pbw-stier-asciicast -o json` → `not_found` |
| 15 | asciicast's WEB render is client-hydration-dependent (asciinema `.ap-player` via `hydratePortableDoc`) — the un-hydrated server output IS the web degrade | `bp task get rpu-backlog-asciicast-full-render-proof -o json \| python3 -c 'import json,sys;print(json.load(sys.stdin)["doc"]["content"]["description"])'` |
| 16 | A PRIOR canonical-set derivation exists (shell-and-cache lane, 2026-07-23): JS 66 test-pinned · Elixir 75 canonical + 6 drift aliases · Go 82 (+1 internal PdSheet); "dashboard" Go-TUI-only | `bp paper view barkpark-tasks-mobile-shell-and-cache \| sed -n '460,480p'` |
| 17 | Go pdrender registry TODAY = 79 keys, one construction site (`DefaultRegistry`), contradicting BOTH the digest's 76 and the paper's 82 | `git grep -oE 'r\.blocks\["[a-z0-9_-]+"\]' origin/main -- internal/pdrender/pdrender.go \| sed 's/.*\["//;s/"\]//' \| sort -u \| wc -l` |
| 18 | react 66-pin and mobile 43-pin both live, at file:line, on origin/main | `git grep -n 'toHaveLength(66)' origin/main -- js/packages/react` · `git grep -n 'toHaveLength(43)' origin/main -- apps/mobile` |
| 19 | Notation prior art rules the math family: "grow the twins, don't buy an engine"; Rung 1 (pure twins) needs NO ruling and is build-ready; a CDN client engine is Rung 2 and hangs on a USER ruling ("is the mermaid CDN pattern a blessed lane or a debt?") | `bp paper view papers-pro-toolkit-notation-typesetting \| sed -n '20,80p'` |
| 20 | `dashboard` IS present in the Go 79 (so "Go-TUI-only sole owner" holds) and is NOT a mobile obligation | `git grep -oE 'r\.blocks\["[a-z0-9_-]+"\]' origin/main -- internal/pdrender/pdrender.go \| grep dashboard` |
