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

  test "LOCK: catalog slugs mirror Registry.known_templates/0 (sorted)" do
    assert Templates.slugs() == Registry.known_templates()
    assert Templates.slugs() == Enum.sort(Templates.slugs())
  end

  test "Templates.get/1 resolves a known slug and rejects an unknown one" do
    assert %{slug: "place-directory", title: "Place Directory"} = Templates.get("place-directory")
    assert Templates.get("wordpress") == nil
    assert Templates.get(nil) == nil
  end
end
