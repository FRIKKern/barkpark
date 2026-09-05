defmodule Barkpark.Api.OpenApiIdempotentRoutesTest do
  @moduledoc """
  bl-api-task-create-idempotency, C2 — the spec must promise dedup on exactly
  the routes that DO it.

  `Barkpark.Api.OpenApi` carries a hand-written `@idempotent_templates`
  allowlist, because the manifest it generates from knows nothing about router
  pipelines. A hand-written list is a claim with a shelf life: mount
  `BarkparkWeb.Plugs.Idempotency` on another pipeline and the spec
  under-promises; UNMOUNT it and the spec promises a retry-safety the server no
  longer provides — the caller then trusts a retry that double-applies, which is
  strictly worse than never advertising the header at all.

  So this file does not read the allowlist. It checks the claim from both ends:

    * OVER-PROMISE, BEHAVIOURALLY — every operation the spec marks with
      `Idempotency-Key` is DRIVEN over real HTTP, twice with one key, and must
      answer `Idempotency-Replay: true`. A route that lost the plug reds here
      even though the spec still says it dedups.
    * UNDER-DECLARATION, STRUCTURALLY — the set of router pipelines that mount
      the plug is pinned. Mounting it on a THIRD pipeline reds, which is the
      moment `@idempotent_templates` needs a new entry.

  `Phoenix.Router.__routes__/0` does not expose `pipe_through` in this Phoenix
  version, so the structural half reads the router source directly rather than
  pretending to a derivation it cannot make.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, TenancyFixtures}

  @router_source Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)
  @token "barkpark-test-openapi-idem"
  @dataset "production"

  # Every pipeline that mounts the dedup plug today. Adding one is not a
  # failure — it is a PROMPT: the new pipeline's routes now dedup, so their path
  # templates belong in `@idempotent_templates` (lib/barkpark/api/openapi.ex)
  # and this list.
  @mounted_on [:scoped_mutate, :idempotent]

  setup do
    {:ok, _} = Auth.create_token(@token, "test-openapi-idem", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    %{ws: ws, project: project}
  end

  defp idempotent_pipelines do
    source = File.read!(@router_source)

    ~r/^  pipeline :(\w+) do\n(.*?)^  end$/ms
    |> Regex.scan(source)
    |> Enum.filter(fn [_, _name, body] ->
      String.contains?(body, "plug(BarkparkWeb.Plugs.Idempotency)")
    end)
    |> Enum.map(fn [_, name, _body] -> String.to_atom(name) end)
    |> Enum.sort()
  end

  # {METHOD, openapi path} for every spec operation declaring the header.
  defp spec_ops do
    Barkpark.Api.OpenApi.spec()
    |> Map.fetch!("paths")
    |> Enum.flat_map(fn {path, ops} ->
      for {method, op} <- ops,
          Enum.any?(Map.get(op, "parameters", []), &(&1["name"] == "Idempotency-Key")),
          do: {String.upcase(method), path}
    end)
    |> Enum.sort()
  end

  test "the source regex still matches — otherwise the structural half is vacuous" do
    refute Enum.empty?(idempotent_pipelines()),
           "no router pipeline mounts BarkparkWeb.Plugs.Idempotency — either the plug moved " <>
             "or this test's regex stopped matching; both make the comparison below vacuous"
  end

  test "the dedup plug is mounted on exactly the pipelines the spec was written against" do
    assert idempotent_pipelines() == Enum.sort(@mounted_on),
           "the set of pipelines running BarkparkWeb.Plugs.Idempotency changed. Their routes " <>
             "now dedup (or stopped): update `@idempotent_templates` in " <>
             "lib/barkpark/api/openapi.ex, re-run `mix barkpark.openapi`, and update " <>
             "@mounted_on here."
  end

  test "the spec declares the header on at least one operation" do
    refute Enum.empty?(spec_ops()),
           "no operation declares Idempotency-Key — the behavioural test below would pass " <>
             "over an empty list"
  end

  test "EVERY operation the spec marks idempotent actually replays", ctx do
    for {"POST", path} <- spec_ops() do
      url =
        path
        |> String.replace("{workspace_slug}", ctx.ws.slug)
        |> String.replace("{project_slug}", ctx.project.slug)
        |> String.replace("{dataset}", @dataset)

      key = "openapi-idem-#{System.unique_integer([:positive])}"
      body = Jason.encode!(%{"mutations" => [%{"create" => %{"_type" => "post", "title" => key}}]})

      first = post(conn_with(key), url, body)

      assert first.status in 200..299,
             "#{url}: first request #{first.status} — #{first.resp_body}"

      second = post(conn_with(key), url, body)

      assert Enum.any?(second.resp_headers, &(&1 == {"idempotency-replay", "true"})),
             "OVER-PROMISE at #{url}: the spec advertises Idempotency-Key here, but a " <>
               "repeat with the same key was NOT replayed (status #{second.status}). A " <>
               "client trusting this spec would double-apply on retry."

      assert second.resp_body == first.resp_body
    end
  end

  defp conn_with(key) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
  end
end
