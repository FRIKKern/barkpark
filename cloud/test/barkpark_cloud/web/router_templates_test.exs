defmodule BarkparkCloud.Web.RouterTemplatesTest do
  @moduledoc """
  dwb-6 — the PUBLIC template catalog `GET /v1/templates` the `/new?template=`
  deploy-button card renders. Proves:

    * public (no auth) — it's the marketing surface a logged-out visitor sees
    * shape — each row carries slug/title/description/env_keys/repo the card +
      Vercel-clone handoff consume; env_keys are KEYS only (no values/secrets)
    * LOCK: the catalog slugs == Registry.known_templates/0 (itself lock-tested
      against the Go worker's embedded allowlist) — no silent drift on which
      templates exist.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test

  alias BarkparkCloud.{Registry, Templates}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "GET /v1/templates is public and lists the catalog with the card's display fields" do
    conn = Router.call(conn(:get, "/v1/templates"), @opts)

    assert conn.status == 200
    %{"templates" => templates} = json_body(conn)
    assert is_list(templates)
    assert length(templates) == length(Registry.known_templates())

    blog = Enum.find(templates, &(&1["slug"] == "blog-starter"))
    assert blog["title"] == "Blog Starter"
    assert is_binary(blog["description"]) and blog["description"] != ""
    assert is_list(blog["what_you_get"]) and blog["what_you_get"] != []
    assert blog["framework"] == "nextjs"
    assert blog["repo"] =~ "github.com"
    assert is_binary(blog["docs"])

    # env_keys are KEYS the Vercel clone URL prefills — never values/secrets.
    assert "BARKPARK_TOKEN" in blog["env_keys"]
    assert "BARKPARK_WEBHOOK_SECRET" in blog["env_keys"]
  end

  test "no secret or value ever appears in the catalog payload" do
    conn = Router.call(conn(:get, "/v1/templates"), @opts)
    body = conn.resp_body
    # A crude but effective guard: the payload must not carry any 'value' or
    # 'secret' key — only 'env_keys' (the discipline that this stays keys-only).
    refute body =~ ~s("value")
    refute body =~ ~s("secret")
  end

  test "LOCK: catalog slugs mirror Registry.known_templates/0" do
    # The mirror equality IS the drift lock. Declaration order is display
    # order (new templates insert at the head — scaffy add-site-template),
    # so sortedness is deliberately NOT pinned.
    assert Templates.slugs() == Registry.known_templates()
  end

  test "Templates.get/1 resolves a known slug and rejects an unknown one" do
    assert %{slug: "place-directory", title: "Place Directory"} = Templates.get("place-directory")
    assert Templates.get("wordpress") == nil
    assert Templates.get(nil) == nil
  end

  # stw12-copy-honesty-content-lock — a FAILABLE content lock on the flagship's
  # served copy. The catalog is the public marketing surface, so a false claim
  # regressing into it (a fabricated block COUNT, a `listings map` that is dead
  # on managed deploys, or an unqualified `typo-tolerant` promise implying a
  # fuzzy engine) must RED the suite, not ship silently. Proven failable: put
  # `(all 42 block types)` back on the served search-starter row and this REDs.
  test "LOCK: the served catalog is exactly the five known slugs (literal pin)" do
    conn = Router.call(conn(:get, "/v1/templates"), @opts)
    %{"templates" => templates} = json_body(conn)

    served = templates |> Enum.map(& &1["slug"]) |> MapSet.new()

    # A LITERAL set — not derived from the catalog under test — so adding or
    # removing a template without updating this pin reds here.
    pinned =
      MapSet.new([
        "astro-search-starter",
        "blog-starter",
        "place-directory",
        "search-starter",
        "website-starter"
      ])

    assert served == pinned
  end

  test "LOCK: the flagship search-starter copy carries no false claims" do
    conn = Router.call(conn(:get, "/v1/templates"), @opts)
    %{"templates" => templates} = json_body(conn)

    search = Enum.find(templates, &(&1["slug"] == "search-starter"))
    assert search, "search-starter must be in the served catalog"

    # Every string the row ships to the marketing surface.
    copy = Enum.join([search["description"] | search["what_you_get"]], "\n")

    # No fabricated block COUNT — the canonical PortableDoc renders "all block
    # types"; pinning a number (42/60/77) rots the moment the grammar grows.
    refute copy =~ "block types",
           "search-starter copy must not pin a PortableDoc block count"

    refute copy =~ ~r/\d+ block/,
           "search-starter copy must not state a numeric block count"

    # The `listings map` is dead on managed deploys — cut for reachability (D89).
    refute copy =~ "listings map",
           "search-starter copy must not advertise the listings map"

    # No unqualified typo-tolerance promise implying a client/indx fuzzy engine —
    # widening is server-side Postgres trigram and the copy must say so.
    refute copy =~ "typo-tolerant",
           "search-starter copy must not make an unqualified typo-tolerant claim"

    assert search["description"] =~ "Postgres trigram",
           "search-starter description must attribute widening to Postgres trigram"
  end
end
