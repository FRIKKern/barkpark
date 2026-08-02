# CCH wave 22 verify — `cruel-name-inadmissible`: re-derivation recipes

Pinned tree: `origin/main` = `974d412caec6fd7023764f43595bee714226581b` (2026-08-02).
Subject: wave 21's `fleet-cruel-content` fixture asserts `name.length === 255`. The ONLY
person-reachable create derives `slug = slugify(name)` and caps the slug at 63.

## R1 — the fixture's own cap constants and its 255-char `cruelName`

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | sed -n '1389,1445p'

Expect `const BARKPARK_NAME_MAX = 255; // registry/barkpark.ex:466` and the throw
`cruel fixture: name is ${cruelName.length} chars, the server's cap is ${BARKPARK_NAME_MAX}`.

## R2 — derive the slug the server would compute from that name

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs > /tmp/scen_main.mjs
    node -e 'import("/tmp/scen_main.mjs").then(m=>{const b=m.SCENARIOS["fleet-cruel-content"].data.barkparks[0];const s=b.name.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"");console.log("name",b.name.length,"slug",s.length,"admissible",s.length<=63,"fixture slug field",JSON.stringify(b.slug))})'

Expect `name 255 slug 254 admissible false fixture slug field "produksjon"`.
NOTE: the worktree copy of `scenarios.mjs` may predate the cruel fixture — read from
`origin/main`, never the checkout (`grep -c cruel cloud/priv/static/__preview__/scenarios.mjs`
returned 0 here).

## R3 — the real Elixir `slugify/1`, run rather than reimplemented

    elixir -e 'slugify = fn n -> b = n |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"); if b == "", do: "bp-FALLBACK", else: b end; c = "Produksjon redaksjonsinnholdsplattformenforflersprakligpubliseringinorden arkiv og rettighetsstyring for alle avdelinger og datterselskaper i den nordiske forlagsgruppen, inkludert distribusjon og metadata for samtlige utgivelser fra 1892 og fram til 2026"; s = slugify.(c); IO.puts("name=#{String.length(c)} slug=#{String.length(s)}")'

Expect `name=255 slug=254`. Source of the copied body:
`git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '11241,11256p'`.

## R4 — the cap that rejects it, and the insert path that applies it

    git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | sed -n '465,472p'
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '180,198p'

Expect `validate_length(:slug, min: 1, max: 63)` and
`insert_barkpark/2` → `Barkpark.changeset(...) |> Repo.insert()`.

## R5 — the create route chain (person-reachable) and its 422

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5151,5152p;7891,7891p;7970,7972p'

Expect `post("/v1/launch", do: go_live(conn))`, `post("/v1/go-live", ...)`,
`slug = if(is_binary(name), do: slugify(name), else: nil)`, and
`{:error, %Ecto.Changeset{} = changeset} -> json(conn, 422, ...)`.

## R6 — the negatives: no rename route, no user-facing slug parameter

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n '^  \(put\|patch\|post\) "/v1/barkparks'
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'body_params\["slug"\]'

Expect NO bare `POST/PUT/PATCH "/v1/barkparks"` or `.../:id` name-update route (only
`:id/<action>` verbs), and exactly two `body_params["slug"]` hits: `5615` (worker-token
`POST /v1/internal/barkparks`) and `5894` (`POST /v1/sites`). Neither is a Barkpark rename.

## R7 — the admissibility rule, stated as an equation and verified

`slug_len(name) = Σ|maximal ASCII-alnum runs| + (#INTERIOR non-alnum runs)`; leading and
trailing non-alnum runs are free (`String.trim("-")`). Admissible iff `slug_len <= 63`.

    elixir -e 'fmt = ~r/^[a-z0-9][a-z0-9-]*$/; slugify = fn n -> b = n |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"); if b == "", do: "bp-FALLBACK", else: b end; ck = fn l, n -> s = slugify.(n); IO.puts("#{l}: name=#{String.length(n)} slug=#{String.length(s)} ok63=#{String.length(s)<=63} fmt=#{Regex.match?(fmt,s)}") end; ck.("A63","Gyldendal Norsk Forlag arkiv og rettighetsstyring i Norden ASAB"); ck.("A64","Gyldendal Norsk Forlag arkiv og rettighetsstyring i Norden ASABC"); ck.("B", String.duplicate("ø",254) <> "x"); ck.("C", String.duplicate("a",63) <> String.duplicate("·",192))'

Expect:
```
A63: name=63 slug=63 ok63=true  fmt=true
A64: name=64 slug=64 ok63=false fmt=true
B:   name=255 slug=1  ok63=true fmt=true
C:   name=255 slug=63 ok63=true fmt=true
```
Reading: a normal single-space ASCII name slugifies 1:1, so the EFFECTIVE cap on an ordinary
typed name is **63**, not 255. A 255-char name is admissible only when >=192 of its characters
are non-ASCII-alnum arranged as leading/trailing padding or multi-character interior runs.
Non-ASCII LETTERS (`æ ø å`) are 1:1 too — they buy budget only in runs.

## R8 — the empty-alnum fallback slug is invalid ~8.4% of the time

    elixir -e 'fmt = ~r/^[a-z0-9][a-z0-9-]*$/; bad = for _ <- 1..2000, do: ("bp-" <> (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase())); n = Enum.count(bad, &(not Regex.match?(fmt, &1))); IO.puts("invalid=#{n}/2000")'

Expect ~168/2000 (8.4%). `Base.url_encode64/2`'s alphabet contains `_`, which
`@slug_format ~r/^[a-z0-9][a-z0-9-]*$/` (`registry/barkpark.ex:47`) rejects — so a name with
ZERO ASCII-alnum characters 422s nondeterministically. Independent latent defect; not the
subject claim.

## R9 — the name column is wide enough (contrast with `env_var.comment`)

    for f in $(git ls-tree -r origin/main --name-only cloud/priv/repo/migrations); do git show origin/main:$f | grep -q 'create table(:barkparks' && git show origin/main:$f | grep -n 'add :name'; done

Expect `add :name, :string, null: false` in `20260626193000_create_barkparks.exs` — varchar(255),
character-counted, so a 255-character name IS storable. The 255 cap is real; it is just not
EFFECTIVE, because the slug derivation binds first.
