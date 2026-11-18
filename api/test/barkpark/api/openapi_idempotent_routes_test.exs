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

  alias Barkpark.{Auth, Content, TenancyFixtures}
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

  # A RATCHET, now empty: every route that runs the plug is declared
  # (task-e3c146574ea3e8bf declared the twelve this list held). A new covered
  # route is declared, never added here.
  @undeclared_today []

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

  # The Sanity-spelled scoped mutate: declared by `idempotent?/1`, but no
  # manifest command lists it, so it is not a spec operation. Its clients
  # (@sanity/client) are still told it dedups, so it is driven below too.
  @sanity_mutate "/w/:workspace_slug/p/:project_slug/v:api_version/data/mutate/:dataset"
  @ops_type "openapiidem"

  # Router templates whose replay is driven: every spec operation marked
  # idempotent (the over-promise check), plus every covered route
  # `idempotent?/1` declares, so a declared route the manifest omits is driven
  # too.
  defp driven_templates do
    elsewhere = Enum.map(@driven_elsewhere, &router_template/1)

    from_spec = for {"POST", path} <- spec_ops(), do: router_template(path)

    from_router =
      for {:post, template} <- covered(BarkparkWeb.Router, @lib_dir),
          OpenApi.idempotent?(template),
          do: template

    Enum.uniq(from_spec ++ from_router) -- elsewhere
  end

  defp router_template(path), do: Regex.replace(~r/\{(\w+)\}/, path, ":\\1")

  test "EVERY declared route actually replays", ctx do
    templates = driven_templates()

    assert @sanity_mutate in templates,
           "the Sanity-spelled scoped mutate is no longer declared, so it is not driven"

    for template <- templates do
      {params, body} = recipe(template, ctx)
      url = fill(template, Map.merge(base_params(ctx), params))
      body = Jason.encode!(body)
      key = "openapi-idem-#{System.unique_integer([:positive])}"

      first = post(conn_with(key), url, body)

      assert first.status in 200..299,
             "#{url}: first request #{first.status} — #{first.resp_body}"

      second = post(conn_with(key), url, body)

      assert Enum.any?(second.resp_headers, &(&1 == {"idempotency-replay", "true"})),
             "OVER-PROMISE at #{url}: Idempotency-Key is declared here, but a repeat " <>
               "with the same key was NOT replayed (status #{second.status}). A client " <>
               "trusting the spec would double-apply on retry."

      assert second.resp_body == first.resp_body
    end
  end

  defp base_params(ctx) do
    %{
      "workspace_slug" => ctx.ws.slug,
      "project_slug" => ctx.project.slug,
      "dataset" => @dataset,
      "api_version" => "2021-06-07"
    }
  end

  defp fill(template, params),
    do: Regex.replace(~r/:(\w+)/, template, fn _, name -> Map.fetch!(params, name) end)

  # One request that answers 2xx on a fresh fixture, per declared route. A
  # route with no recipe flunks: declaring a route means driving its replay.
  defp recipe(template, ctx) do
    suffix = String.replace_prefix(template, "/w/:workspace_slug/p/:project_slug", "")

    case Regex.run(~r{^/v(?:1|:api_version)(/.*)$}, suffix, capture: :all_but_first) do
      [rest] -> recipe_for(rest, ctx)
      nil -> flunk("no request recipe for #{template}")
    end
  end

  defp recipe_for("/data/mutate/:dataset", _ctx) do
    id = "openapi-idem-#{System.unique_integer([:positive])}"
    {%{}, %{"mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => id}}]}}
  end

  defp recipe_for("/data/doc/:dataset/:type/:doc_id/ops", ctx) do
    {id, rev} = ops_doc!(ctx)
    op = %{"op" => "append-block", "block" => para("p1")}
    {%{"type" => @ops_type, "doc_id" => id}, %{"op" => op, "ifRev" => rev}}
  end

  defp recipe_for("/data/doc/:dataset/:type/:doc_id/fields/:field/ops", ctx) do
    {id, rev} = ops_doc!(ctx)
    ops = [%{"op" => "append-block", "block" => para("p1")}]

    {%{"type" => @ops_type, "doc_id" => id, "field" => "body"}, %{"ops" => ops, "ifRev" => rev}}
  end

  defp recipe_for("/data/disconnect/:dataset/:doc_id", _ctx),
    do: {%{"doc_id" => "openapi-idem-#{System.unique_integer([:positive])}"}, %{}}

  defp recipe_for("/papers/:slug/masters", ctx),
    do: {%{"slug" => elem(paper!(ctx), 0)}, %{"blockId" => "sec"}}

  defp recipe_for("/papers/:slug/masters/:master_id/insert", ctx) do
    {slug, _rev} = paper!(ctx)
    {%{"slug" => slug, "master_id" => master!(ctx, slug)}, %{"mode" => "detached"}}
  end

  defp recipe_for("/papers/:slug/masters/blocks/:block_id/pin", ctx) do
    {slug, block_id} = linked_block!(ctx)
    {%{"slug" => slug, "block_id" => block_id}, %{"pin" => true}}
  end

  defp recipe_for("/papers/:slug/masters/blocks/:block_id/detach", ctx) do
    {slug, block_id} = linked_block!(ctx)
    {%{"slug" => slug, "block_id" => block_id}, %{}}
  end

  defp recipe_for("/papers/:slug/ops", ctx) do
    {slug, rev} = paper!(ctx)

    op = %{
      "op" => "append-block",
      "block" => %{"id" => "b1", "type" => "paragraph", "text" => "x"}
    }

    {%{"slug" => slug}, %{"ops" => [op], "ifRev" => rev}}
  end

  defp recipe_for(rest, _ctx),
    do:
      flunk("no request recipe for #{rest}: a declared route needs one, so its replay is driven")

  defp scope(ctx), do: [workspace_id: ctx.ws.id, project_id: ctx.project.id]

  defp para(id),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => id}]}

  # A document of a schema with a block-editor field; answers its published id
  # and current rev (the ops routes require `ifRev`).
  defp ops_doc!(ctx) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @ops_type,
          "title" => "OpenAPI idempotency",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText", "editor" => "blocks"}
          ]
        },
        @dataset,
        scope(ctx)
      )

    id = "oi-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(@ops_type, %{"doc_id" => id, "title" => "T"}, @dataset, scope(ctx))

    {id, doc.rev}
  end

  defp paper!(ctx) do
    slug = "openapi-idem-#{System.unique_integer([:positive])}"

    section = %{
      "id" => "sec",
      "type" => "section",
      "blocks" => [%{"id" => "sec-p", "type" => "paragraph", "text" => "Master copy"}]
    }

    {:ok, paper} =
      %{slug: slug, blocks: [section], workspace_id: ctx.ws.id, project_id: ctx.project.id}
      |> Barkpark.LabelFixtures.paper_attrs()
      |> Content.upsert_paper()

    {slug, paper.content["rev"]}
  end

  # Fixtures are set up through the same routes WITHOUT a key, so only the
  # request under test is keyed.
  defp master!(ctx, slug) do
    resp = post(authed(), papers_url(ctx, slug, "/masters"), Jason.encode!(%{"blockId" => "sec"}))
    Jason.decode!(resp.resp_body)["docId"] || flunk("master save: #{resp.resp_body}")
  end

  defp linked_block!(ctx) do
    {slug, _rev} = paper!(ctx)
    master_id = master!(ctx, slug)
    body = Jason.encode!(%{"mode" => "linked"})
    resp = post(authed(), papers_url(ctx, slug, "/masters/#{master_id}/insert"), body)

    case Jason.decode!(resp.resp_body) do
      %{"blockIds" => [block_id]} -> {slug, block_id}
      other -> flunk("linked insert: #{inspect(other)}")
    end
  end

  defp papers_url(ctx, slug, rest),
    do: "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/papers/#{slug}#{rest}"

  defp authed do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp conn_with(key), do: put_req_header(authed(), "idempotency-key", key)
end
