defmodule BarkparkWeb.ScopedSearchIntelReceiptTest do
  @moduledoc """
  The WORKSPACE-SCOPED MIRROR of the search-intel receipts, dispatched to for
  the first time.

  `correction_receipt_test.exs` and `interaction_receipt_test.exs` pin the
  correction and interaction receipts over real HTTP on the FLAT routes only —
  `post("/search/:dataset/correction", SearchController, :correction)` and
  `post("/search/:dataset/interaction", SearchController, :search_interaction)`
  inside `scope "/v1/data"` on `pipe_through([:api, :api_grant_read])`. Both
  moduledocs say, correctly, that they prove nothing about the mirror.

  The mirror mounts the SAME three `SearchController` actions
  (`:search_suggestions`, `:search_interaction`, `:correction`) under
  `scope "/w/:workspace_slug/p/:project_slug"` on `pipe_through(:scoped_api)`,
  with a `/v1/data/search/:dataset/...` suffix. Every case in the flat files
  misses it — the two extra path segments mean no request has ever reached that
  pipeline for these actions. Three things were therefore ASSUMED, and this
  file runs each of them:

    1. WHAT `:scoped_api` ADMITS. The pipeline is
       AcceptBarkparkVendor → accepts json → ApiSecurityHeaders →
       ErrorEnvelopeNegotiation → RateLimit → `scoped_api_optional_credential`
       → `Plugs.ResolveWorkspace` → `Plugs.ResolveProject` → TenantLogMetadata.
       `ResolveWorkspace` is mounted with NO options, so
       `allow_anonymous_default:` is false and its membership gate is hard: an
       anonymous conn carries no `:api_token` and no `:current_user`, fails
       `Tenancy.Auth.authorize/3`, and halts on `{:error,
       :forbidden_membership}`. So the mirror is NOT an anonymous surface the
       way its flat twin is — the same POST that answers 200 without a header
       on `/v1/data/...` is refused 403 under `/w/:ws/p/:proj/v1/data/...`.
       Both statuses are asserted here, side by side, from a real request.

    2. WHETHER THE RECEIPT SURVIVES THE PIPELINE. The five-way correction
       receipt and the four-way interaction receipt are asserted on the scoped
       path AND compared, case for case, against the flat path's body in the
       same run — so a divergence introduced by the scoped pipeline cannot hide
       behind a body that merely "looks right".

    3. WHETHER THE TENANT IS STAMPED. `SearchController` builds its record opts
       with `workspace_id: workspace_id(conn)`, which reads
       `conn.assigns[:current_workspace]` — the assign `ResolveWorkspace` makes.
       The written row is read back and its `workspace_id` asserted.

  ## Non-vacuity, stated because a stamp test is easy to fake

  The interaction path inherits its tenant: `Intelligence.do_record_interaction/4`
  writes `Keyword.get(opts, :workspace_id) || search.workspace_id`. A parent
  search event seeded with the workspace already on it would therefore satisfy
  the stamp assertion even if the controller passed `nil`. So the parent event
  in the stamp case is seeded with `workspace_id: nil` on purpose: the only
  path by which the child row can carry the workspace is the conn's own assign.

  ## Verdict

  The scoped pipeline is CORRECT as mounted — it fails closed for an anonymous
  caller, admits a member, returns byte-identical receipts, and stamps the
  resolved workspace on the row. This file is the proof of that, not a fix for
  it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content.SearchIntelligence
  alias Barkpark.Repo
  alias Barkpark.Search.Event

  @dataset "production"

  # A NUL byte survives normalization, reaches Postgres inside the `query`
  # :string column and is rejected there — the `rescue` in
  # `record_correction/4` turns it into `status: :error`. Same instrument the
  # flat file uses, so the two paths are compared on identical inputs.
  @nul_from "corection" <> <<0>> <> "typo"

  # int4 column, int8 value: the insert raises on parameter encoding and
  # `record_interaction/4` answers `{:skipped, :error}` → HTTP 500.
  @int4_overflow "3000000000"

  setup %{conn: conn} do
    # The flat comparison arm resolves the seeded Default workspace.
    {_default_ws, _default_proj} = ensure_default_scope!()

    ws = create_workspace!("ssir-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "ssir-proj-#{System.unique_integer([:positive])}")

    Repo.delete_all(from(e in Event, where: e.surface == "documents"))

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp member_token!(ws) do
    raw = "ssir-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "ssir-member", @dataset, ["read"], ws.id)
    raw
  end

  defp scoped_path(ws, proj, suffix),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/search/#{@dataset}#{suffix}"

  defp with_headers(conn, headers),
    do: Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp correction_rows do
    Repo.aggregate(
      from(e in Event, where: e.surface == "documents" and e.event_type == "correction"),
      :count
    )
  end

  defp reset_documents_events do
    Repo.delete_all(from(e in Event, where: e.surface == "documents"))
  end

  # A parent search event with NO workspace — see "Non-vacuity" above.
  defp tenantless_parent_event do
    {:ok, id} =
      SearchIntelligence.record(@dataset, %{"q" => "scoped receipt pin"}, 3, 7,
        actor_key: "anon",
        workspace_id: nil
      )

    %Event{workspace_id: nil} = Repo.get(Event, id)
    id
  end

  defp error_code(resp) do
    case Jason.decode(resp.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> "<unparseable body>"
    end
  end

  describe "C0 — what :scoped_api actually admits (a run, not a read of the pipeline)" do
    test "an ANONYMOUS caller is refused on all three scoped search-intel routes", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      correction =
        post(conn, scoped_path(ws, proj, "/correction"), %{
          "from" => "corection",
          "to" => "correction"
        })

      refute_rate_limited!(correction)

      assert correction.status == 403,
             "anonymous POST #{scoped_path(ws, proj, "/correction")} — :scoped_api mounts " <>
               "ResolveWorkspace with no allow_anonymous_default, so the membership gate must " <>
               "halt; got #{correction.status}"

      assert error_code(correction) == "forbidden"

      interaction =
        post(conn, scoped_path(ws, proj, "/interaction"), %{
          "queryEventId" => Ecto.UUID.generate(),
          "objectId" => "doc-scoped-1"
        })

      refute_rate_limited!(interaction)
      assert interaction.status == 403
      assert error_code(interaction) == "forbidden"

      suggestions = get(conn, scoped_path(ws, proj, "/suggestions?q=cor"))

      refute_rate_limited!(suggestions)
      assert suggestions.status == 403
      assert error_code(suggestions) == "forbidden"

      # The refusal is a refusal, not a silent no-op that also wrote.
      assert correction_rows() == 0
    end

    test "a MEMBER-TOKEN caller is admitted on all three scoped search-intel routes", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = member_token!(ws)

      correction =
        conn
        |> bearer(raw)
        |> post(scoped_path(ws, proj, "/correction"), %{
          "from" => "corection",
          "to" => "correction"
        })

      refute_rate_limited!(correction)
      assert correction.status == 200

      parent = tenantless_parent_event()

      interaction =
        conn
        |> bearer(raw)
        |> post(scoped_path(ws, proj, "/interaction"), %{
          "queryEventId" => parent,
          "objectId" => "doc-scoped-1"
        })

      refute_rate_limited!(interaction)
      assert interaction.status == 200

      suggestions =
        conn
        |> bearer(raw)
        |> get(scoped_path(ws, proj, "/suggestions?q=cor"))

      refute_rate_limited!(suggestions)
      assert suggestions.status == 200
    end

    test "a member of ANOTHER workspace is refused — the gate keys on the URL's tenant", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      other = create_workspace!("ssir-other-#{System.unique_integer([:positive])}")
      raw = member_token!(other)

      resp =
        conn
        |> bearer(raw)
        |> post(scoped_path(ws, proj, "/correction"), %{
          "from" => "corection",
          "to" => "correction"
        })

      refute_rate_limited!(resp)
      assert resp.status == 403
      assert error_code(resp) == "forbidden"
      assert correction_rows() == 0
    end
  end

  describe "C1 — the receipts survive the scoped pipeline unchanged" do
    test "the five-way correction receipt is identical on the scoped and flat paths", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = member_token!(ws)

      cases = [
        {:recorded, %{"from" => "corection", "to" => "correction"}, [], 1},
        {:recording_disabled, %{"from" => "corection", "to" => "correction"},
         [{"x-bp-search-disable", "1"}], 0},
        {:blank, %{"from" => "   ", "to" => "correction"}, [], 0},
        {:identical, %{"from" => "Correction", "to" => "correction"}, [], 0},
        {:error, %{"from" => @nul_from, "to" => "correction"}, [], 0}
      ]

      receipts =
        Enum.map(cases, fn {label, params, headers, expected_rows} ->
          reset_documents_events()

          scoped =
            conn
            |> bearer(raw)
            |> with_headers(headers)
            |> post(scoped_path(ws, proj, "/correction"), params)

          refute_rate_limited!(scoped)
          scoped_receipt = {scoped.status, json_response(scoped, 200)}
          scoped_rows = correction_rows()

          assert scoped_rows == expected_rows,
                 "#{label}: scoped path expected #{expected_rows} correction row(s), " <>
                   "got #{scoped_rows}"

          reset_documents_events()

          flat =
            conn
            |> with_headers(headers)
            |> post(~p"/v1/data/search/#{@dataset}/correction", params)

          refute_rate_limited!(flat)
          flat_receipt = {flat.status, json_response(flat, 200)}

          assert scoped_receipt == flat_receipt,
                 "#{label}: the scoped mirror and the flat route disagree — " <>
                   "scoped #{inspect(scoped_receipt)} vs flat #{inspect(flat_receipt)}"

          {label, scoped_receipt}
        end)

      assert length(Enum.uniq(Enum.map(receipts, &elem(&1, 1)))) == 5,
             "five causally different outcomes collapsed on the SCOPED path: " <>
               inspect(receipts, pretty: true)
    end

    test "the four-way interaction receipt is identical on the scoped and flat paths", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = member_token!(ws)

      cases = [
        {:recorded, fn parent -> %{"queryEventId" => parent, "objectId" => "doc-scoped-1"} end,
         [], 200},
        {:recording_disabled,
         fn parent -> %{"queryEventId" => parent, "objectId" => "doc-scoped-1"} end,
         [{"x-bp-search-disable", "1"}], 200},
        {:incomplete_reference, fn parent -> %{"queryEventId" => parent} end, [], 422},
        {:unknown_query_event,
         fn _parent ->
           %{"queryEventId" => Ecto.UUID.generate(), "objectId" => "doc-scoped-1"}
         end, [], 422},
        {:error,
         fn parent ->
           %{
             "queryEventId" => parent,
             "objectId" => "doc-scoped-1",
             "position" => @int4_overflow
           }
         end, [], 500}
      ]

      receipts =
        Enum.map(cases, fn {label, build_params, headers, expected_status} ->
          reset_documents_events()

          scoped =
            conn
            |> bearer(raw)
            |> with_headers(headers)
            |> post(scoped_path(ws, proj, "/interaction"), build_params.(parent_event()))

          refute_rate_limited!(scoped)

          assert scoped.status == expected_status,
                 "#{label}: scoped mirror answered #{scoped.status}, expected #{expected_status}"

          scoped_body = json_response(scoped, expected_status)

          reset_documents_events()

          flat =
            conn
            |> with_headers(headers)
            |> post(~p"/v1/data/search/#{@dataset}/interaction", build_params.(parent_event()))

          refute_rate_limited!(flat)
          flat_body = json_response(flat, expected_status)

          # `interactionEventId` is a fresh row id per request and is the ONE
          # field that must differ; every other field carries the receipt.
          comparable = &Map.drop(&1, ["interactionEventId"])

          assert comparable.(scoped_body) == comparable.(flat_body),
                 "#{label}: the scoped mirror and the flat route disagree — " <>
                   "scoped #{inspect(scoped_body)} vs flat #{inspect(flat_body)}"

          {label, {scoped.status, comparable.(scoped_body)}}
        end)

      # Four controller arms, five cases: the two `{:skipped, other}` inputs
      # share the 422 status and separate on `reason`, so all five receipts are
      # distinct and no outcome is readable as another.
      assert length(Enum.uniq(Enum.map(receipts, &elem(&1, 1)))) == 5,
             "the recorded / disabled / 422 / 500 arms must stay distinguishable on the " <>
               "SCOPED path: " <> inspect(receipts, pretty: true)
    end
  end

  describe "C2 — the scoped path stamps the resolved tenant on the written row" do
    test "a scoped correction writes a row carrying the URL's workspace_id", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = member_token!(ws)

      body =
        conn
        |> bearer(raw)
        |> post(scoped_path(ws, proj, "/correction"), %{
          "from" => "corection",
          "to" => "correction"
        })
        |> json_response(200)

      assert body["status"] == "recorded"

      row =
        Repo.one!(
          from(e in Event, where: e.surface == "documents" and e.event_type == "correction")
        )

      assert row.workspace_id == ws.id,
             "the scoped correction row must carry the workspace the URL resolved " <>
               "(#{ws.id}); got #{inspect(row.workspace_id)}"
    end

    test "a scoped interaction stamps the tenant even when the parent event has none", %{
      conn: conn,
      ws: ws,
      proj: proj
    } do
      raw = member_token!(ws)
      parent = tenantless_parent_event()

      body =
        conn
        |> bearer(raw)
        |> post(scoped_path(ws, proj, "/interaction"), %{
          "queryEventId" => parent,
          "objectId" => "doc-scoped-1",
          "position" => 2,
          "type" => "select"
        })
        |> json_response(200)

      assert body["recorded"] == true

      row = Repo.get(Event, body["interactionEventId"])

      assert row, "recorded:true handed back an interactionEventId with no event row behind it"
      assert row.event_type == "select"
      assert row.query_event_id == parent

      assert row.workspace_id == ws.id,
             "the scoped interaction row must carry the workspace the URL resolved " <>
               "(#{ws.id}); the parent event carried nil, so nothing but the conn's " <>
               "`:current_workspace` assign can have supplied it. Got " <>
               "#{inspect(row.workspace_id)}"
    end
  end

  # A parent search event for the interaction arms. Tenant-free by design (see
  # the moduledoc): it must never be the source of the child row's workspace.
  defp parent_event, do: tenantless_parent_event()
end
