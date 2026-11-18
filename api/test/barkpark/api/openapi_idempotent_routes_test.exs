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
    * UNDER-DECLARATION, STRUCTURALLY — every mutating route the plug covers
      is derived, and each must be one `OpenApi.idempotent?/1` declares. The
      derivation is `Barkpark.Test.IdempotencyMounts`, shared with the
      streaming tripwire: a route's pipelines come from
      `Phoenix.Router.route_info/4`, so a route `plugin_routes(scope: ...)`
      emits into an Idempotency scope counts; and every file under `lib/` that
      names the plug is read, so a plugin controller under
      `lib/barkpark/plugins/*/web/` that mounts it counts
      (task-d909ad1c50dd5a1a). The pins this replaces named pipelines and read
      only `lib/barkpark_web/controllers/`, so neither moved for those.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, TenancyFixtures}
  alias Barkpark.Api.OpenApi
  alias Barkpark.Test.IdempotencyMounts

  @lib_dir Path.expand("../../../lib", __DIR__)
  @token "barkpark-test-openapi-idem"
  @dataset "production"

  # Spec operations whose replay is driven in their own test file, because a
  # 2xx needs more than a mutate body (a chat send needs a session and a
  # runtime). Listed by path so a NEW advertised route cannot hide here.
  @driven_elsewhere ["/v1/chat/sessions/{id}/messages"]
  @chat_send_test Path.expand(
                    "../../barkpark_web/controllers/chat_send_idempotency_key_test.exs",
                    __DIR__
                  )

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "test-openapi-idem",
        "test",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    %{ws: ws, project: project}
  end

  # A plugin-shaped router (`IdempotencyMounts.compile_plugin_fixture!/2`),
  # compiled once under its own module names.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "bp-openapi-idem-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{fixture: IdempotencyMounts.compile_plugin_fixture!(dir, "OpenApiPlugin")}
  end

  # `{verb, path}` for every mutating route the dedup plug covers: through a
  # pipeline or a scope piping the plug, or through its controller's own mount.
  defp covered(router, lib_root) do
    by_pipeline =
      for {verb, path, _, _} <- IdempotencyMounts.pipeline_routes(router), do: {verb, path}

    by_controller =
      for {verb, path, _, _, _} <- IdempotencyMounts.controller_routes(router, lib_root),
          do: {verb, path}

    Enum.sort(Enum.uniq(by_pipeline ++ by_controller))
  end

  defp undeclared(router, lib_root),
    do: Enum.reject(covered(router, lib_root), fn {_verb, path} -> OpenApi.idempotent?(path) end)

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

  test "CONTROL: the derived set holds the mutate route, its scoped mirror and the chat send" do
    covered = covered(BarkparkWeb.Router, @lib_dir)

    for route <- [
          {:post, "/v1/data/mutate/:dataset"},
          {:post, "/w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset"},
          {:post, "/v1/chat/sessions/:id/messages"}
        ] do
      assert route in covered,
             "the derivation lost #{inspect(route)}, so the check below measures less. " <>
               "Covered: #{inspect(covered)}"
    end
  end

  # Routes that ran the plug, but were not declared, when this pin was first
  # derived. The old pins named pipelines, so a route added to an existing
  # pipeline never moved them. Declaring these is task-e3c146574ea3e8bf. A
  # RATCHET: a route declared since must leave this list, and a new covered
  # route is declared, never added here.
  @undeclared_today [
    {:post, "/v1/data/disconnect/:dataset/:doc_id"},
    {:post, "/v1/data/doc/:dataset/:type/:doc_id/fields/:field/ops"},
    {:post, "/v1/data/doc/:dataset/:type/:doc_id/ops"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/disconnect/:dataset/:doc_id"},
    {:post,
     "/w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id/fields/:field/ops"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id/ops"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/papers/:slug/masters"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/papers/:slug/masters/:master_id/insert"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/papers/:slug/masters/blocks/:block_id/detach"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/papers/:slug/masters/blocks/:block_id/pin"},
    {:post, "/w/:workspace_slug/p/:project_slug/v1/papers/:slug/ops"},
    {:post, "/w/:workspace_slug/p/:project_slug/v:api_version/data/mutate/:dataset"}
  ]

  test "every route the dedup plug covers is declared idempotent in the spec" do
    undeclared = undeclared(BarkparkWeb.Router, @lib_dir)

    assert undeclared -- @undeclared_today == [],
           "these routes run BarkparkWeb.Plugs.Idempotency, but the spec does not offer " <>
             "Idempotency-Key on them: add their templates to `@idempotent_templates` in " <>
             "lib/barkpark/api/openapi.ex and re-run `mix barkpark.openapi`. " <>
             inspect(undeclared -- @undeclared_today)

    assert @undeclared_today -- undeclared == [],
           "these are declared now (or no longer run the plug): remove them from " <>
             "@undeclared_today. #{inspect(@undeclared_today -- undeclared)}"
  end

  # task-d909ad1c50dd5a1a: the two doors the old pins could not see.
  test "MUTANT: a plugin route in an Idempotency scope and a plugin controller's own mount red",
       %{fixture: fixture} do
    undeclared = undeclared(fixture.router, fixture.lib_root)

    assert {:post, "/v1/plugins/calm"} in undeclared,
           "plugin_routes(scope: ...) emitted a route into an :idempotent scope; a pin that " <>
             "names pipelines does not move for it. Got: #{inspect(undeclared)}"

    assert {:post, "/v1/open/self"} in undeclared,
           "a controller under barkpark/plugins/*/web/ mounts the plug; a pin that reads " <>
             "only barkpark_web/controllers/ does not see it. Got: #{inspect(undeclared)}"

    assert {:post, "/v1/direct/stream"} in undeclared
    refute {:post, "/v1/open/stream"} in undeclared, "a route with no mount is not covered"
  end

  test "the spec declares the header on at least one operation" do
    refute Enum.empty?(spec_ops()),
           "no operation declares Idempotency-Key — the behavioural test below would pass " <>
             "over an empty list"
  end

  test "an operation driven elsewhere is still advertised, and its test file exists" do
    for path <- @driven_elsewhere do
      assert {"POST", path} in spec_ops(), "#{path} is no longer advertised idempotent"
    end

    assert File.exists?(@chat_send_test), "#{@chat_send_test} is gone"
  end

  test "EVERY operation the spec marks idempotent actually replays", ctx do
    for {"POST", path} <- spec_ops(), path not in @driven_elsewhere do
      url =
        path
        |> String.replace("{workspace_slug}", ctx.ws.slug)
        |> String.replace("{project_slug}", ctx.project.slug)
        |> String.replace("{dataset}", @dataset)

      key = "openapi-idem-#{System.unique_integer([:positive])}"

      body =
        Jason.encode!(%{"mutations" => [%{"create" => %{"_type" => "post", "title" => key}}]})

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
