defmodule BarkparkWeb.FlatAliasTenancyTest do
  @moduledoc """
  Fail-before protective test for task-28c3f7f0987d6e85 — the flat `/v1/*` alias
  ignored the token's workspace binding, so any valid bearer read (and wrote)
  the seeded Default Workspace's data.

  ## The mechanism

  The `:api` pipeline ran `OptionalToken` (assigns `:api_token`, NOT
  `:current_workspace`) and then `AssignDefaultScope`, whose whole job is to
  stamp `current_workspace = <seeded Default>` when nothing else did. On the
  flat routes nothing else ever did — there is no `/w/:ws/p/:project` in the
  path for `ResolveWorkspace` to read — so EVERY caller converged on Default.
  A token bound to workspace B, correctly refused `not_a_member` on
  `/w/default/p/default/v1/data/counts/production`, read Default's entire census
  through the flat `/v1/data/counts/production`.

  `:flat_admin_api` (D45/D49) and `:cycle_api` (B9) already carried the fix:
  `DeriveWorkspaceFromToken` ahead of `AssignDefaultScope`. This extends it to
  `:api`, the pipeline behind the rest of the flat alias.

  ## Why the assertions are on IDENTITY

  These routes answered 200 while talking to the wrong workspace, so a status
  assertion is vacuous. Every test here reads the rows actually returned.

  RED on origin/main; GREEN with the derivation on `:api`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"
  @type_name "flat-alias-post"
  @token_b "flat-alias-token-b"
  @token_default "flat-alias-token-default"
  @write_token_b "flat-alias-write-token-b"
  @write_token_default "flat-alias-write-token-default"
  @pipeline :api

  setup do
    # The Default Workspace must EXIST for the defect to manifest —
    # AssignDefaultScope is a no-op on a DB that never got the backfill, and
    # that is precisely the configuration in which this bug is invisible.
    {default_ws, default_project} = TenancyFixtures.ensure_default_scope!()
    default_scope = [workspace_id: default_ws.id, project_id: default_project.id]

    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)
    scope_b = [workspace_id: ws_b.id, project_id: project_b.id]

    seed_schema!(default_scope)
    seed_schema!(scope_b)

    # Default holds THREE documents of the type; B holds ONE. The counts alone
    # therefore identify which workspace answered.
    for i <- 1..3, do: seed_doc!("default-#{i}", default_scope)
    seed_doc!("b-1", scope_b)

    {:ok, _} = Auth.create_token(@token_b, "flat-alias-b", @dataset, ["read"], ws_b.id)

    {:ok, _} =
      Auth.create_token(@token_default, "flat-alias-default", @dataset, ["read"], default_ws.id)

    # The WRITE arm needs write-capable twins of the two read tokens above:
    # `:require_write` gates /v1/data/mutate, so a read-only token 403s at the
    # gate and never reaches the scope resolution this test is about.
    {:ok, _} =
      Auth.create_token(
        @write_token_b,
        "flat-alias-write-b",
        @dataset,
        ["read", "write"],
        ws_b.id
      )

    {:ok, _} =
      Auth.create_token(
        @write_token_default,
        "flat-alias-write-default",
        @dataset,
        ["read", "write"],
        default_ws.id
      )

    %{default_ws: default_ws, default_scope: default_scope, ws_b: ws_b, scope_b: scope_b}
  end

  defp seed_schema!(scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_name,
          "fields" => [%{"name" => "title", "type" => "string"}],
          # `public` so the anonymous control below can read it at all — the
          # tenancy question is orthogonal to visibility.
          "visibility" => "public"
        },
        @dataset,
        scope
      )
  end

  defp seed_doc!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, published} = Content.publish_document(doc.doc_id, @type_name, @dataset, scope)
    published
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp counts(resp), do: resp.resp_body |> Jason.decode!() |> counts_map()

  # The counts payload has grown a wrapper before; read it shape-tolerantly so
  # this test fails on TENANCY, never on an envelope rename.
  defp counts_map(%{"counts" => counts}) when is_map(counts), do: counts
  defp counts_map(%{"result" => %{"counts" => counts}}) when is_map(counts), do: counts
  defp counts_map(%{"result" => result}) when is_map(result), do: result
  defp counts_map(body) when is_map(body), do: body

  # ── The defect ────────────────────────────────────────────────────────────

  describe "the flat alias answers from the TOKEN's workspace" do
    test "GET /v1/data/counts/:dataset returns B's census, not Default's", %{conn: conn} do
      resp = conn |> authed(@token_b) |> get("/v1/data/counts/#{@dataset}")

      assert resp.status == 200

      assert counts(resp)[@type_name] == 1,
             "the flat alias answered workspace B's token with #{inspect(counts(resp))} — " <>
               "B holds ONE #{@type_name}; THREE is the seeded Default Workspace's census " <>
               "leaking through the alias (task-28c3f7f0987d6e85)"
    end

    test "CONTROL — the scoped path already refused this token (403 not_a_member)",
         %{conn: conn} do
      resp = conn |> authed(@token_b) |> get("/w/default/p/default/v1/data/counts/#{@dataset}")

      assert resp.status == 403,
             "the scoped surface must keep refusing a non-member — if this drifts, the " <>
               "flat assertion above proves nothing about tenancy"
    end
  end

  # ── The controls: the fix must not brick the alias ────────────────────────

  describe "controls — what the derivation must NOT change" do
    test "a token bound to the Default Workspace still resolves to Default", %{conn: conn} do
      resp = conn |> authed(@token_default) |> get("/v1/data/counts/#{@dataset}")

      assert resp.status == 200

      assert counts(resp)[@type_name] == 3,
             "a Default-bound token must still see Default's three documents — a " <>
               "single-tenant instance is byte-identical after this change"
    end

    test "the anonymous public-read surface still serves the flat alias", %{conn: conn} do
      # No bearer at all → DeriveWorkspaceFromToken is a no-op → AssignDefaultScope
      # stamps Default exactly as before. The alias is not bricked.
      resp = get(conn, "/v1/data/query/#{@dataset}/#{@type_name}")

      assert resp.status == 200

      ids =
        resp.resp_body
        |> Jason.decode!()
        |> get_in(["result", "documents"])
        |> List.wrap()
        |> Enum.map(& &1["_id"])

      assert "default-1" in ids,
             "the anonymous flat read stopped serving the Default Workspace's published " <>
               "documents — got #{inspect(ids)} from #{resp.resp_body}"
    end
  end

  # ── The WRITE arm ─────────────────────────────────────────────────────────

  describe "the flat alias WRITES into the TOKEN's workspace" do
    # `arpss-flat-doc-mutate-default-scope-write`, ruling DERIVE-TOKEN-WORKSPACE
    # (reads and writes together). The READ arm above is pinned; this is the
    # write twin: a workspace-bound token POSTing the flat
    # /v1/data/mutate/:dataset must have its document STAMPED with its own
    # workspace, never with the seeded singleton Default.
    #
    # The assertion is on the STORED row, not the response: mutate answered 200
    # while stamping Default, so a status assertion is vacuous here exactly as
    # it is on the read arm.
    test "a workspace-B token's create lands in B, not Default",
         %{conn: conn, ws_b: ws_b, default_ws: default_ws} do
      # Non-vacuity, part 1: the two workspaces are distinct and both non-nil,
      # so "stamped B" and "stamped Default" are actually different outcomes.
      assert is_binary(ws_b.id) and is_binary(default_ws.id)
      refute ws_b.id == default_ws.id

      resp = flat_create(conn, @write_token_b, "flat-write-b")

      assert resp.status == 200, "flat write failed: #{resp.status} #{resp.resp_body}"

      # Non-vacuity, part 2: the row EXISTS. A missing row would make any
      # workspace assertion pass by vacuous pattern-match.
      doc = stored!("flat-write-b")

      assert doc.workspace_id == ws_b.id,
             "the flat mutate stamped workspace #{inspect(doc.workspace_id)} on a token " <>
               "bound to workspace B (#{ws_b.id}); the seeded Default Workspace is " <>
               "#{default_ws.id} — a Default stamp is the missing DeriveWorkspaceFromToken " <>
               "on `pipeline :api` (arpss-flat-doc-mutate-default-scope-write)"

      refute doc.workspace_id == default_ws.id
    end

    test "CONTROL — a Default-bound token's flat create still lands in Default",
         %{conn: conn, ws_b: ws_b, default_ws: default_ws} do
      resp = flat_create(conn, @write_token_default, "flat-write-default")

      assert resp.status == 200, "flat write failed: #{resp.status} #{resp.resp_body}"

      doc = stored!("flat-write-default")

      assert doc.workspace_id == default_ws.id,
             "a Default-bound token must keep writing into the Default Workspace — a " <>
               "single-tenant instance is byte-identical after the derivation"

      refute doc.workspace_id == ws_b.id
    end
  end

  # ── Plug ORDER is the fix ─────────────────────────────────────────────────

  describe "plug ORDER is the fix — a reorder must go red" do
    # DeriveWorkspaceFromToken is no-op-if-set. Placed AFTER AssignDefaultScope
    # it can never fire, because Default has already been stamped. The
    # behavioural tests above catch that too; this reads the ordering DIRECTLY
    # so the failure names the cause instead of a symptom.
    #
    # Block-scoped, not line-anchored: it finds `pipeline :<name> do … end` by
    # name, so inserting lines anywhere in router.ex cannot slide it.
    test "#{@pipeline} derives the workspace from the token BEFORE the Default fallback" do
      plugs = pipeline_plugs(@pipeline)

      resolve = index_of!(plugs, "OptionalToken", @pipeline)
      derive = index_of!(plugs, "DeriveWorkspaceFromToken", @pipeline)
      default = index_of!(plugs, "AssignDefaultScope", @pipeline)

      assert resolve < derive,
             "OptionalToken must assign :api_token before DeriveWorkspaceFromToken reads " <>
               "it (pipeline #{@pipeline}: #{inspect(plugs)})"

      assert derive < default,
             "DeriveWorkspaceFromToken is NO-OP-IF-SET: placed after AssignDefaultScope " <>
               "it can never fire and every flat caller collapses to the Default " <>
               "Workspace (pipeline #{@pipeline}: #{inspect(plugs)})"
    end

    test "every flat pipeline that stamps the Default scope derives from the token first" do
      # The census, as an invariant rather than a snapshot: ANY pipeline that
      # runs AssignDefaultScope must run DeriveWorkspaceFromToken ahead of it,
      # unless it resolves no token at all (nothing to derive from). A new flat
      # pipeline that forgets the derivation reopens this exact defect.
      offenders =
        for name <- pipeline_names(),
            plugs = pipeline_plugs(name),
            "AssignDefaultScope" in plugs,
            Enum.any?(plugs, &(&1 in ~w(OptionalToken RequireToken RequireBearerOrSessionToken))),
            derive = Enum.find_index(plugs, &(&1 == "DeriveWorkspaceFromToken")),
            default = Enum.find_index(plugs, &(&1 == "AssignDefaultScope")),
            is_nil(derive) or derive > default,
            do: {name, plugs}

      assert offenders == [],
             """
             A pipeline resolves a token and then stamps the seeded Default Workspace
             without deriving the token's OWN workspace first, so every caller on it
             converges on Default (task-28c3f7f0987d6e85):

             #{inspect(offenders, pretty: true)}
             """
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  defp router_source, do: File.read!(@router_path)

  defp pipeline_names do
    ~r/^  pipeline :([a-z_]+) do$/m
    |> Regex.scan(router_source())
    |> Enum.map(fn [_, name] -> name end)
  end

  # The plug module basenames of `pipeline :name do … end`, in source order.
  defp pipeline_plugs(name) do
    src = router_source()

    [_, block] =
      Regex.run(~r/^  pipeline :#{name} do\n(.*?)^  end$/ms, src) ||
        flunk("router.ex has no `pipeline :#{name}` block")

    ~r/^\s*plug\(([^),]+)/m
    |> Regex.scan(block)
    |> Enum.map(fn [_, arg] -> arg |> String.trim() |> String.split(".") |> List.last() end)
  end

  defp index_of!(plugs, plug, pipeline) do
    case Enum.find_index(plugs, &(&1 == plug)) do
      nil -> flunk("pipeline :#{pipeline} no longer runs #{plug} — got #{inspect(plugs)}")
      i -> i
    end
  end
  # ── write-arm helpers ─────────────────────────────────────────────────────

  defp flat_create(conn, token, doc_id) do
    body =
      Jason.encode!(%{
        "mutations" => [
          %{"create" => %{"_id" => doc_id, "_type" => @type_name, "title" => doc_id}}
        ]
      })

    conn |> authed(token) |> post("/v1/data/mutate/#{@dataset}", body)
  end

  # The stored row, read straight from the DB with NO tenancy scope, so the
  # lookup cannot itself be the thing under test. `_id: "x"` is persisted as
  # the draft `doc_id` "drafts.x"; accept both so a doc_id convention change
  # reds on the workspace assertion rather than on a missing row.
  defp stored!(doc_id) do
    rows =
      Repo.all(
        from(d in Document,
          where: d.type == ^@type_name and d.doc_id in ^[doc_id, "drafts." <> doc_id]
        )
      )

    case rows do
      [doc] ->
        doc

      other ->
        flunk(
          "expected exactly ONE stored #{@type_name} row for #{inspect(doc_id)}, got " <>
            inspect(Enum.map(other, &{&1.doc_id, &1.workspace_id}))
        )
    end
  end
end
