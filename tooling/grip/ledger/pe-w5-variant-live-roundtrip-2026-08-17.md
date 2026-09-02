<!-- doc-tier: cold | canonical-for: pe-w5-variant-live-roundtrip-recipe | budget: 900tok -->

# PE W5 — variant=framed live round-trip re-derivation recipe

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Verifier assignment `variant-live-roundtrip`. Proves the bp/API write path
preserves `variant="framed"` verbatim AND pins the exact condition under which
the served `/papers/` HTML carries `class="bp-section--framed"`.

Server: `https://guerrilla.barkpark.cloud` (admin token in `~/.config/barkpark/config`).
origin/main HEAD at capture: `a9d29985d63d0cce926e7f8ec5d1b46666b92af0`.

## Re-run (create → read-back → publish → serve → delete → 404)

```bash
# 1. create scratch draft with a framed section + paragraph child
bp doc create paper --yes --set _id=pe-w5-variant-probe-scratch \
  --set title="PE W5 Variant Probe Scratch" \
  --set 'blocks:=[{"type":"section","id":"s1","title":"Probe","variant":"framed","blocks":[{"type":"paragraph","content":[{"type":"text","value":"probe"}]}]}]'

# 2. read back the DRAFT (the create lands as drafts.<id>, NOT the bare id) — variant survives verbatim
bp doc get paper 'drafts.pe-w5-variant-probe-scratch' --perspective raw -o json | grep -o '"variant":"framed"'

# 3. publish wall needs description(>=20ch) + a REGISTERED tag (crown-proof) + style=article for the class
bp doc patch paper pe-w5-variant-probe-scratch --yes \
  --set description="Scratch probe verifying variant framed survives the bp write path and renders in served HTML." \
  --set 'tags:=[{"tag":"crown-proof","strength":50,"rationale":"scratch verification"}]' \
  --set style="article"
bp doc publish paper pe-w5-variant-probe-scratch --yes

# 4. served class — grep the CONTENT, excluding <style>. Bare `grep -c bp-section--framed` = 3 = CSS FALSE POSITIVE.
curl -s https://guerrilla.barkpark.cloud/papers/pe-w5-variant-probe-scratch \
  | python3 -c "import sys,re;h=sys.stdin.read();print(re.sub(r'<style.*?</style>','',h,flags=re.S).count('bp-section--framed'))"
#   -> 1  (only when style=article; 0 without it)

# 5. cleanup — ONE delete clears published + draft
bp doc delete paper pe-w5-variant-probe-scratch --yes
curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/papers/pe-w5-variant-probe-scratch   # -> 404
```

## The load-bearing findings

1. `variant="framed"` survives the write path verbatim (draft raw + published get both show `"variant":"framed"`).
2. The served class is `:article`-GATED. `bulldocs_live.ex` renders `:article`
   palette only when `content["style"] == "article"` (`paper_article?/1`,
   `render_opts(true) => %{style: :article}`); `walk.ex box_class_attr` emits the
   whitelisted class ONLY under `%{style: :article}` (compose.ex stamps it on the
   PdBox; walk.ex emits it). A paper WITHOUT `style:"article"` renders the framed
   section as a plain inline hr band — NO class.
3. The finale slice's acceptance grep must (a) require target papers to be
   `style:"article"`, and (b) grep `class="bp-section--framed"` with the `<style>`
   block stripped — bare `grep -c 'bp-section--framed'` counts 3 CSS references and
   lies green on a paper where the class never renders.
