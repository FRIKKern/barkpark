defmodule BarkparkWeb.SearchScopeSeatMatrixTest do
  @moduledoc """
  `GET /v1/data/search/:dataset` adjudicated BY RUNNING IT, in BOTH seat states
  (task-40d8ac114d3902b2).

  ## The disagreement this file settles

  Two instruments were on the record and could not both be right:

    * **The census** — the search door leaks across tenants ONLY when the
      Default workspace seat is VACANT.
    * **A code read** — the `:shared_only` sentinel cannot reach that door at
      all, so the seat state is irrelevant.

  The rule the filing itself states is that "two instruments disagreeing is
  exactly when neither should be quoted", so nothing here is decided by reading.
  Each arm below is an HTTP request against the real router, and the seat state
  is the independent variable — set explicitly per arm and PROVED before the
  assertion, never inherited from whatever the migration seeded.

  `search_scope_shared_layer_test.exs` (PR #15243) already pins the VACANT arm
  and the caller-supplied-`?workspace_id=` arm. It does not pin the OCCUPIED
  arm, and its self-test proves only that the probe can see the row it is
  ENTITLED to. This file adds the missing half of the matrix and a stronger
  control.

  ## The control, and why a clean result is worthless without it

  An anonymous search is narrowed twice before tenancy is even consulted — the
  W10 schema-visibility gate admits PUBLIC types only, and the perspective clamp
  admits PUBLISHED rows only — and the dataset leaf is resolved through
  `Content.resolve_read_dataset_id/2`, which behaves differently depending on
  whether a workspace key is present. Any one of those can make the foreign row
  unreachable for a reason that has nothing to do with the tenant boundary, and
  the arm would then record "no leak" from a surface it cannot see at all.

  `LEAK-OBSERVABILITY CONTROL` fires the SAME path, the SAME dataset and the
  SAME query string as the leak arms, differing ONLY in that the caller is
  entitled to workspace A's row — and asserts the row COMES BACK. It runs in
  both seat states, because the seat is exactly the variable under study. If a
  control ever reds, every refutation in this file is blindness and must not be
  quoted.

  ## Assertions are on the BYTES and on the resolved ids

  This surface answers `200` leaking and `200` not; only the marker
  discriminates. Both the substring and the structural `documents[]._id` are
  checked so an absence survives a future change to response shaping.
  """
  # `async: false`: vacating the seat writes the one `workspaces` row every
  # other suite reads, so this must not run beside them.
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Tenancy.Workspace

  # ONE dataset string shared by both tenants — isolation must come from
  # `workspace_id`, never from the dataset leaf.
  @ds "search-seat-matrix"

  @foreign_marker "ZzarquonSeatMatrixForeign"
  @shared_marker "ZzarquonSeatMatrixShared"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds
      )

    # NULL THE SCHEMA ROW'S SCOPE EXPLICITLY, same reason as the shared
    # document below. `upsert_schema/2` runs unscoped, but `WriteScope` still
    # stamps an unscoped write with whatever workspace currently occupies the
    # Default seat — so at setup time (before any test vacates it) the schema
    # row lands OWNED by the seeded Default, not shared-layer. The anonymous
    # :shared_only sentinel narrows the schema-visibility allowlist
    # (`Content.Schema.public_type_names/2` -> `scope_to_workspace_or_global`)
    # to `workspace_id IS NULL` rows only, so a Default-owned "post" schema
    # drops OUT of that allowlist entirely: `d.type in []` -> every anonymous
    # search under the vacant seat goes WHERE false, and the door reads as
    # "no leak" for a reason that has nothing to do with tenancy — the exact
    # blindness the moduledoc's control paragraph warns about. The bound
    # LEAK-OBSERVABILITY CONTROL doesn't catch this because its token bypasses
    # the schema-visibility gate entirely (`bypasses_visibility_gate?/1` — any
    # non-public-read api_token). Anonymous is the only caller that reaches
    # this gate, so only an anonymous-caller assertion (the SHARED-layer arm
    # below) can observe it.
    {n_schema, _} =
      from(s in Barkpark.Content.SchemaDefinition,
        where: s.name == ^"post" and s.dataset == ^@ds
      )
      |> Repo.update_all(set: [workspace_id: nil, project_id: nil])

    assert n_schema > 0, "the schema fixture matched no rows — it is not shared-layer"

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)

    {:ok, _} =
      create_document_in!(
        ws_a,
        proj_a,
        "post",
        %{"doc_id" => "seat-foreign-doc", "title" => "#{@foreign_marker} Doc"},
        @ds
      )

    {:ok, _} =
      Content.publish_document("seat-foreign-doc", "post", @ds,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # The shared layer (workspace_id IS NULL) — what an UNRESOLVED caller is
    # supposed to receive, and the thing a fix that over-reaches would destroy.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "seat-shared-doc", "title" => "#{@shared_marker} Doc"},
        @ds,
        []
      )

    {:ok, _} = Content.publish_document("seat-shared-doc", "post", @ds, [])

    # NULL THE SHARED ROW EXPLICITLY. `WriteScope` stamps an unscoped write with
    # the SEEDED DEFAULT workspace, so the two writes above produced
    # Default-OWNED rows, not shared-layer ones — the seat is still occupied at
    # setup time here (each arm sets it afterwards). A fixture that merely omits
    # the scope does not produce `workspace_id IS NULL`; it has to be said. This
    # is the same move, for the same reason, that
    # `empty_scope_shared_layer_test.exs` makes for its own shared row.
    #
    # It is also the whole reason the over-reach guard below reddened on the
    # first run: not a scoping defect, a fixture that never held the shape it
    # claimed. Both the draft and the published row carry the doc_id.
    {n, _} =
      from(d in Barkpark.Content.Document, where: d.doc_id == ^"seat-shared-doc")
      |> Repo.update_all(set: [workspace_id: nil, project_id: nil])

    assert n > 0, "the shared-layer fixture matched no rows — it is not shared-layer"

    # The control's credential: a read token BOUND to workspace A. It is the
    # entitled caller — the one for whom returning A's row is CORRECT.
    raw_a = "seat-matrix-a-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw_a, "seat-matrix-a", @ds, ["read"], ws_a.id)

    %{ws_a: ws_a, raw_a: raw_a}
  end

  # ── seat control ────────────────────────────────────────────────────────────

  # Vacate by RENAMING the slug, not by deleting the row.
  # `Tenancy.get_default_workspace/0` is a `Repo.get_by(Workspace, slug:
  # "default")`, so a renamed row is an absent seat for every reader, and the
  # write is one UPDATE against one row. Deleting cascades FK checks across
  # projects/documents in an order other suites take differently — a lock CYCLE
  # (Postgres 40P01), not mere contention.
  defp vacate_seat! do
    {1, _} =
      from(w in Workspace, where: w.slug == "default")
      |> Repo.update_all(set: [slug: "default-vacated-#{System.unique_integer([:positive])}"])

    refute Tenancy.get_default_workspace(),
           "the seat is still OCCUPIED — the vacant arm would pass by " <>
             "tenant-equality instead of by the sentinel, i.e. vacuously"

    :ok
  end

  defp occupy_seat! do
    case Tenancy.get_default_workspace() do
      nil ->
        w = create_workspace!("default")
        _ = create_project!(w)
        w

      w ->
        w
    end
  end

  defp search(conn, q), do: get(conn, "/v1/data/search/#{@ds}", q: q)

  defp with_token(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp doc_ids(body) do
    body
    |> Jason.decode!()
    |> Map.get("documents", [])
    |> Enum.map(&(&1["_id"] || &1["id"]))
  end

  @q String.downcase(@foreign_marker)

  # ── LEAK-OBSERVABILITY CONTROL — read these two FIRST ───────────────────────

  describe "LEAK-OBSERVABILITY CONTROL" do
    test "seat VACANT: the entitled caller DOES receive workspace A's row", %{
      conn: conn,
      raw_a: raw_a
    } do
      vacate_seat!()

      resp = conn |> with_token(raw_a) |> search(@q)
      assert resp.status == 200

      assert resp.resp_body =~ @foreign_marker,
             "CONTROL RED: with the seat vacant, not even a caller BOUND to " <>
               "workspace A can see A's own row through this door — so the " <>
               "anonymous refutation below is blindness, not isolation, and " <>
               "must not be quoted"

      assert "seat-foreign-doc" in doc_ids(resp.resp_body)
    end

    test "seat OCCUPIED: the entitled caller DOES receive workspace A's row", %{
      conn: conn,
      raw_a: raw_a
    } do
      assert occupy_seat!()

      resp = conn |> with_token(raw_a) |> search(@q)
      assert resp.status == 200

      assert resp.resp_body =~ @foreign_marker,
             "CONTROL RED: with the seat occupied, the entitled caller cannot " <>
               "see A's row — the occupied arm below proves nothing"

      assert "seat-foreign-doc" in doc_ids(resp.resp_body)
    end
  end

  # ── the matrix: the same door, the same query, both seat states ─────────────

  describe "the search door, both ways" do
    test "seat VACANT + anonymous: workspace A's row does NOT come back", %{conn: conn} do
      vacate_seat!()

      resp = search(conn, @q)
      assert resp.status == 200

      refute resp.resp_body =~ @foreign_marker,
             "GET /v1/data/search/#{@ds} returned another tenant's document to a " <>
               "caller that resolved NO workspace — the empty-scope class, back " <>
               "open on the search read path"

      refute "seat-foreign-doc" in doc_ids(resp.resp_body)
    end

    # The census claimed the leak was SEAT-CONDITIONAL. This arm measures the
    # other half of that claim. Its mechanism is NOT the sentinel: with a seat,
    # `AssignDefaultScope` stamps the Default workspace and the read is narrowed
    # by tenant EQUALITY. Stated plainly so nobody later mistakes this green for
    # sentinel coverage — the vacant arm above is the one the sentinel owns, and
    # the mutation proof rides on that one.
    test "seat OCCUPIED + anonymous: workspace A's row does NOT come back either", %{
      conn: conn
    } do
      assert occupy_seat!()

      resp = search(conn, @q)
      assert resp.status == 200

      refute resp.resp_body =~ @foreign_marker,
             "GET /v1/data/search/#{@ds} returned another tenant's document to an " <>
               "anonymous caller stamped with the Default workspace"

      refute "seat-foreign-doc" in doc_ids(resp.resp_body)
    end

    # The over-reach guard. A fix that closed the door by narrowing an
    # unresolved caller to NOTHING would pass every refutation above while
    # breaking every legacy install. An unresolved caller must still receive the
    # shared layer.
    test "seat VACANT + anonymous: the SHARED layer still arrives", %{conn: conn} do
      vacate_seat!()

      resp = search(conn, String.downcase(@shared_marker))
      assert resp.status == 200

      assert resp.resp_body =~ @shared_marker,
             "an unresolved caller lost the shared (workspace_id IS NULL) layer — " <>
               "the door was closed by blinding it, not by scoping it"

      assert "seat-shared-doc" in doc_ids(resp.resp_body)
    end
  end
end
