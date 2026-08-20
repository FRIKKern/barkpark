# acrc walk-site census — children→Enum.map sites (origin/main 328f8288)

Verifier re-derivation for the content-render-robustness wave. Line numbers drift; re-derive by pattern.

## Claim
16 distinct `Map.get(n, "children", [])` sites in walk.ex feed a null-unsafe `Enum.map`; 5 of them bypass both shared helpers. No 12th missed kind. compose.ex `render_children/2` is a distinct, already-coercing decoy.

## Rerun (walk.ex census)
```
git show origin/main:api/lib/barkpark/portable_doc/render/walk.ex \
  | grep -nE 'Map.get\(n, "children"|render_children|paragraph_inner|Enum.map'
git show origin/main:api/lib/barkpark/portable_doc/render/walk.ex \
  | grep -cE 'Map\.get\(n, "children", \[\]\)'   # => 16
```

## The 16 sites (all string-key `Map.get(n,"children",[])`; default fires only on ABSENT key → present null yields nil → Enum.map(nil) raises)
- Routed via `render_children/3` (defp :1599, `children |> Enum.map(&walk)` — NO is_list guard): 188, 198, 212, 1434, 1447, 1527, 1536, 1543, 1548
- Routed via `paragraph_inner/3` (defp :1609, `children |> Enum.map(fn ...)` — NO is_list guard): 1563, 1569
- INLINE, bypass both helpers, raise on null directly: 283 (PdText), 350/371 (paragraph_html), 424 (heading_inner), 544 (link), 649 (wikilink_label) = 5

Table-cell `render_children(cell, …)` calls (1008,1022,1048,1063) pass `cell`, not Map.get(n,"children") — still route through the unguarded :1599 helper.

## No 12th kind
Exhaustive accessor grep `'"children"|\["children"\]|get_in|:children'` returns ONLY the 16 Map.get sites + defp `paragraph(%{"children" => []}, …)` guard (:326, matches empty-list only, null falls through to :350) + the two helper defps. No `n["children"]`, no `get_in`, no atom `:children`. Census COMPLETE.

## walk/3 catch-all (:175)
`def walk(_, _width, _pal), do: ""` — mirror shape for the fix's `when not is_list(children) -> ""`.

## Decoy (compose.ex)
```
git show origin/main:api/lib/barkpark/portable_doc/render/compose.ex | sed -n '2269,2271p'
```
```
2269:  def render_children(blocks, style \\ :email)
2270:  def render_children(blocks, style) when is_list(blocks), do: render_blocks(blocks, style)
2271:  def render_children(_, _), do: ""
```
Distinct arity-2 function, already coerces non-list → "" via catch-all. Patching HERE = vacuous green.
