# Re-derivation recipes — equation-no-island-proof (mobile blocks wave, 2026-07-26)

Verifier lane: ground the T2-empty ruling for `equation`. Every row re-derives from a clean checkout.

| # | Claim | Command |
|---|---|---|
| 1 | @barkpark/react suite green (15 files / 322 tests) | `cd js && pnpm --filter @barkpark/react test` |
| 2 | equation covered by 2 react tests (type-keyed wrapper + Elixir-golden DOM shape) | `cd js/packages/react && pnpm vitest run tests/PortableDoc.parity.test.tsx tests/PortableDoc.test.tsx --reporter=verbose 2>&1 \| grep -i equation` |
| 3 | Go TUI equation renderer green (5 tests) | `go test ./internal/pdrender/ -run 'Equation' -v` |
| 4 | macro tables byte-identical across the 3 surfaces (43 entries, same values) | `python3` diff of `\|`\\macro`: "sym"\|` in `internal/pdrender/equation.go`, `'\\macro': 'sym'` in `js/packages/react/src/blocks/math.ts`, `"\\macro" => "sym"` in `api/lib/barkpark/portable_doc/render/math.ex` |
| 5 | Elixir MathML twin, live, on arbitrary TeX | `elixir -r api/lib/barkpark/portable_doc/render/util.ex -r api/lib/barkpark/portable_doc/render/math.ex -e 'IO.puts Barkpark.PortableDoc.Render.Math.tex_to_mathml_row("\\frac{a+b}{c}")'` |
| 6 | JS MathML twin, live, on arbitrary TeX | `js/node_modules/.pnpm/esbuild@0.25.12/node_modules/esbuild/bin/esbuild js/packages/react/src/blocks/math.ts --bundle --format=esm --outfile=/tmp/math.mjs --platform=node` then `node --input-type=module -e "import {texToMathMlRow} from '/tmp/math.mjs'; console.log(texToMathMlRow('\\\\frac{a+b}{c}'))"` |
| 7 | Go Unicode twin, live (texToUnicode is unexported — copy equation.go to a scratch `package main`, drop the `Render` method, add a `main()` that prints `texToUnicode(case)`) | see recipe 6 pattern; `go run .` in the scratch dir |
| 8 | cross-surface equation fixture input is only `E = mc^2` (no braces / no `\frac` / no macro) | `grep -n 'equation' api/lib/mix/tasks/barkpark.portable_doc.gen_pd_parity.ex` |
| 9 | mobile has zero equation renderer | `grep -rn equation apps/mobile/src` (no hits) |
| 10 | `texToMathMlRow` is not exported from @barkpark/react (no subpath, not in index) | `grep -rn 'blocks/math' js/packages/react/src` + read `exports` in `js/packages/react/package.json` |
