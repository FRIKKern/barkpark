defmodule BarkparkWeb.ReadPerspectiveStrictTest do
  @moduledoc """
  AN UNSUPPORTED `?perspective` WAS STILL SILENTLY DOWNGRADED TO published ON
  `/v1/data/search/:dataset` AND `/v1/graph/:id` (task-e175c03d3e7722db, the
  class residue of task-857259ad1e7165d2 / PR #13588).

  #13588 made a bogus value a 400 on doc-get and query, matching
  `/v1/data/counts`. It did not reach search or graph, because each of those
  parses the param through its OWN fork:

    * `BarkparkWeb.AnonPerspective.parse/1`                      `def parse(_), do: :published`
    * `BarkparkWeb.SearchController.parse_perspective/1`         a byte-identical copy of it
    * `BarkparkWeb.TasksController.Params.parse_perspective/1`   graph's narrower set + `?drafts=true`

  So `GET /v1/data/search/production?q=x&perspective=drafst` answered 200 over
  the PUBLISHED set and said nothing, while `js/packages/core/src/client.ts`
  threw `BarkparkValidationError` on the same typo — the SDK was stricter than
  the server, which is backwards. A curl caller got the silence the SDK caller
  was spared.

  THE ROUTE LIST IS DERIVED FROM THE MANIFEST, NOT FROM GREP. `docs/openapi.json`
  is generated from `Barkpark.Plugins.Capabilities`; seven route+verb pairs
  declare `?perspective`, and `@declared` below is that list. A grep for
  `parse_perspective` finds three of the four surfaces and misses the fourth,
  which is exactly how this class survived the first pass.

  THE SUPPORTED SETS DIFFER PER ROUTE and the tests hold each route to its OWN
  declared set: `raw` is honoured on the three document surfaces and REFUSED on
  `/v1/graph/:id`, whose manifest entry offers `published | drafts` only.
  Refusing `raw` there is the contract, not a missing branch.

  ORDERING. The refusals are pinned AFTER each route's existence-hiding check —
  `graph_show/2` refuses only inside the `{:ok, root}` arm, so an unknown id
  plus a bogus perspective is still a 404. Otherwise the 400 becomes an
  existence probe on the route with the draft-leak history
  (`graph_draft_leak_test.exs`).

  MUTATION PROOF (pasted in the PR): restoring the silent downgrade on search —
  deleting the `ReadPerspective.unsupported/2` arm in `SearchController.search/2`
  so it falls through to `do_search/3` — reds exactly the two search refusal
  tests below, each naming its route in the failure message. The control tests
  and the graph tests stay green under that mutation, which is what makes them a
  control rather than a second copy of the same assertion.

  FIXTURE ISOLATION: one Postgres is shared by every agent on this box, so this
  suite stands up its OWN workspace, project, token and dataset-scoped rows with
  unique slugs and never reads the whole table.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "production"

  # The seven route+verb pairs that declare `?perspective` in docs/openapi.json,
  # each paired with the value set ITS manifest entry offers. Re-derive with:
  #
  #   python3 -c "import json;s=json.load(open('docs/openapi.json'));\
  #   [print(v.upper(),p) for p,o in sorted(s['paths'].items()) for v,op in o.items() \
  #    if isinstance(op,dict) for q in (op.get('parameters') or []) if q.get('name')=='perspective']"
  #
  # `/v1/graph/:id` has NO `/w/:ws/p/:project` mirror — that is why the count is
  # seven and not eight.
  @document_perspectives ["published", "drafts", "raw"]
  @graph_perspectives ["published", "drafts"]

  setup do
    suffix = System.unique_integer([:positive])
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, ws} = Tenancy.create_workspace(%{slug: "rps-ws-#{suffix}", name: "RPS #{suffix}"})

    {:ok, project} =
      Tenancy.create_project(ws, %{slug: "rps-proj-#{suffix}", name: "RPS proj #{suffix}"})

    raw_token = "barkpark-test-read-perspective-#{suffix}"

    {:ok, _} =
      Auth.create_token(
        raw_token,
        "read-perspective",
        @dataset,
        ["read", "write", "admin"],
        ws.id
      )

    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    doc_id = "rps-doc-#{suffix}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => "Quokka Field Notes #{suffix}", "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, "post", @dataset, scope)

    %{ws: ws, project: project, token: raw_token, doc_id: doc_id, q: "quokka"}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp scoped(ctx, path), do: "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}#{path}"

  # The seven declared pairs as request builders, so the control below cannot
  # quietly cover six of them.
  defp declared_routes(ctx) do
    [
      {"GET /v1/data/doc/{dataset}/{type}/{doc_id}",
       "/v1/data/doc/#{@dataset}/post/#{ctx.doc_id}", @document_perspectives},
      {"GET /v1/data/query/{dataset}/{type}", "/v1/data/query/#{@dataset}/post",
       @document_perspectives},
      {"GET /v1/data/search/{dataset}", "/v1/data/search/#{@dataset}?q=#{ctx.q}",
       @document_perspectives},
      {"GET /v1/graph/{id}", "/v1/graph/#{ctx.doc_id}", @graph_perspectives},
      {"GET /w/{ws}/p/{project}/v1/data/doc/{dataset}/{type}/{doc_id}",
       scoped(ctx, "/v1/data/doc/#{@dataset}/post/#{ctx.doc_id}"), @document_perspectives},
      {"GET /w/{ws}/p/{project}/v1/data/query/{dataset}/{type}",
       scoped(ctx, "/v1/data/query/#{@dataset}/post"), @document_perspectives},
      {"GET /w/{ws}/p/{project}/v1/data/search/{dataset}",
       scoped(ctx, "/v1/data/search/#{@dataset}?q=#{ctx.q}"), @document_perspectives}
    ]
  end

  defp sep(path), do: if(String.contains?(path, "?"), do: "&", else: "?")

  describe "THE DEFECT: an unsupported ?perspective is refused, not downgraded" do
    test "GET /v1/data/search/:dataset answers 400 naming the parameter", ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/v1/data/search/#{@dataset}?q=#{ctx.q}&perspective=zzzbogus")
        |> json_response(400)

      assert body["error"]["details"]["parameter"] == "perspective",
             "GET /v1/data/search/{dataset} did not refuse an unsupported perspective"

      assert body["error"]["details"]["received"] == "zzzbogus"
      assert body["error"]["details"]["supported"] == @document_perspectives

      refute body["documents"],
             "a refused search must not also carry hits — that is the silent downgrade"
    end

    test "the scoped mirror /w/:ws/p/:project/v1/data/search/:dataset answers 400 too", ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get(scoped(ctx, "/v1/data/search/#{@dataset}?q=#{ctx.q}&perspective=zzzbogus"))
        |> json_response(400)

      assert body["error"]["details"]["received"] == "zzzbogus",
             "the scoped search mirror still silently downgraded an unsupported perspective"

      refute body["documents"]
    end

    test "GET /v1/graph/:id answers 400 naming the parameter", ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/v1/graph/#{ctx.doc_id}?perspective=zzzbogus")
        |> json_response(400)

      assert body["error"]["details"]["parameter"] == "perspective",
             "GET /v1/graph/{id} did not refuse an unsupported perspective"

      assert body["error"]["details"]["received"] == "zzzbogus"
      assert body["error"]["details"]["supported"] == @graph_perspectives
      refute body["nodes"], "a refused graph read must not also carry a traversal"
    end

    test "GET /v1/graph/:id refuses `raw` — its manifest entry offers published|drafts only",
         ctx do
      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/v1/graph/#{ctx.doc_id}?perspective=raw")
        |> json_response(400)

      assert body["error"]["details"]["received"] == "raw"

      assert body["error"]["details"]["supported"] == @graph_perspectives,
             "the refusal must quote THIS route's declared set, not the document set"
    end

    test "the refusal is never an existence probe: unknown id + bogus perspective is 404", ctx do
      resp =
        ctx.conn
        |> bearer(ctx.token)
        |> get(
          "/v1/graph/rps-nonexistent-#{System.unique_integer([:positive])}?perspective=zzzbogus"
        )

      assert resp.status == 404,
             "the existence-hiding 404 must beat the perspective 400, or the refusal " <>
               "distinguishes a real id from a nonexistent one on the draft-leak route"
    end
  end

  describe "CONTROL: the SUPPORTED values still work on all seven declared pairs" do
    test "every declared route+verb pair honours every value its manifest entry offers", ctx do
      routes = declared_routes(ctx)

      assert length(routes) == 7,
             "docs/openapi.json declares seven ?perspective route+verb pairs; the control " <>
               "must exercise all of them"

      for {label, path, supported} <- routes, value <- supported do
        status =
          ctx.conn
          |> bearer(ctx.token)
          |> get(path <> sep(path) <> "perspective=" <> value)
          |> Map.fetch!(:status)

        assert status == 200,
               "#{label} regressed on the SUPPORTED value #{inspect(value)}: got #{status}. " <>
                 "Turning a silent downgrade into a 400 must not refuse a value the " <>
                 "manifest declares."
      end
    end

    test "omitting ?perspective entirely is still fine on all seven", ctx do
      for {label, path, _supported} <- declared_routes(ctx) do
        status = ctx.conn |> bearer(ctx.token) |> get(path) |> Map.fetch!(:status)

        assert status == 200, "#{label} regressed with NO ?perspective at all: got #{status}"
      end
    end

    test "graph's ?drafts=true alias survives — it is not spelled `perspective`", ctx do
      status =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/v1/graph/#{ctx.doc_id}?drafts=true")
        |> Map.fetch!(:status)

      assert status == 200,
             "the alias `?drafts=true` is not a `perspective` value and must not be validated " <>
               "against the perspective enum"
    end
  end

  describe "CONTROL: /v1/data/counts is unaffected" do
    test "counts still 200s on published and still 400s anything else with its OWN set", ctx do
      assert ctx.conn
             |> bearer(ctx.token)
             |> get("/v1/data/counts/#{@dataset}?perspective=published")
             |> Map.fetch!(:status) == 200

      body =
        ctx.conn
        |> bearer(ctx.token)
        |> get("/v1/data/counts/#{@dataset}?perspective=drafts")
        |> json_response(400)

      assert body["error"]["details"]["supported"] == ["published"],
             "counts declares published-only; routing it through the shared validator must " <>
               "not widen it to the document set"

      assert body["error"]["message"] =~ "/v1/data/counts",
             "counts keeps its route-specific message through the shared refusal"
    end
  end
end
