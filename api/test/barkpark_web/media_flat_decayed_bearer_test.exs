defmodule BarkparkWeb.MediaFlatDecayedBearerTest do
  @moduledoc """
  The two FLAT media blocks ride bare `:api`, so a DECAYED bearer (revoked /
  expired / never-existed) that names workspace B is silently downgraded to
  anonymous and served the seeded DEFAULT workspace's library with a 200
  (task-6716af864218081b for `/media`, task-79e10984bbb23734 for `/v1/media`).

  MECHANISM (same as task-46872cadcfc50c5f, different mount):
  `OptionalToken`'s fail-soft `_ -> conn` arm assigns nothing on an
  unverifiable bearer, `DeriveWorkspaceFromToken` has no `:api_token` to derive
  from and no-ops, and `AssignDefaultScope` stamps the seeded Default
  workspace/project. `ScopeHelpers.scope_opts/1` then emits Default's ids as
  the `workspace_id` WHERE term for every one of these actions.

  SEVERITY — INTEGRITY / MISLEAD, NOT CONFIDENTIALITY. After the fallthrough
  the conn is byte-identical to a header-less one, and both privilege gates in
  these controllers key on `Barkpark.Media.Storage.Access.authenticated?/1`,
  which is FALSE: `visibility_clamp_opts/1` pins the read to the public tier
  and `render_opts/3` withholds signed URLs. A decayed bearer therefore reads
  NOTHING an anonymous caller could not already read. The harm is a silent
  WRONG ANSWER: revocation is unobservable, and a client cannot tell "my token
  is dead" from "my library is empty".

  THE VACUITY TRAP THIS FILE IS BUILT AGAINST. `Media.Delivery.Search` filters
  on `m.dataset_id` authoritatively whenever a `Dataset` row resolves for the
  (project, slug) pair. A media fixture inserted WITHOUT `dataset_id` is
  therefore excluded from every listing, and each "no foreign rows" refutation
  would pass VACUOUSLY against an empty result set. The first describe block
  below is a POSITIVE CONTROL asserting the listings DO return the seeded rows
  under the right inputs — if a control goes red, no refutation here means
  anything.

  WHAT A FIX MUST NOT BREAK (the controls, pinned per surface):
    * a VALID workspace-B bearer keeps answering B's OWN rows;
    * a caller sending NO Authorization header keeps its anonymous Default
      public read, byte-for-byte. A blanket 401 would break the supported
      public/browser tier and is NOT the remedy;
    * a non-`Bearer` scheme is untouched.

  STATUS AND ENVELOPE, NOT ABSENCE. Each refusal arm asserts `status == 401`
  explicitly, and the canonical arms also assert the envelope's
  `error.code == "unauthorized"`. A bare `refute default_id in ids` also passes
  on an EMPTY 200 — which would replace one silent wrong answer ("here is
  somebody else's library") with another ("your library is empty"), arguably
  worse because it looks like a successful call.

  The refusal deliberately does NOT differentiate revoked from expired from
  unknown: `Auth.verify_token/1`'s fold is documented existence-hiding, and the
  owning lane (`fix-tenant-swap`) pins the byte-equality of those bodies.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Search.Event
  alias Barkpark.{Auth, Media, Repo, Tenancy}

  @dataset "production"

  setup do
    {default_ws, default_project} = ensure_default_scope!()
    default_ds = ensure_dataset!(default_project, @dataset)
    default_file = media_file!(default_ws, default_project, default_ds, "DEFAULT-TENANT-BYTES")

    ws_b = create_workspace!("decayed-b-#{System.unique_integer([:positive])}")
    project_b = create_project!(ws_b, "decayed-b-p-#{System.unique_integer([:positive])}")
    ds_b = ensure_dataset!(project_b, @dataset)
    file_b = media_file!(ws_b, project_b, ds_b, "WORKSPACE-B-BYTES")

    raw_live = "mfdb-live-#{System.unique_integer([:positive])}"
    raw_dead = "mfdb-dead-#{System.unique_integer([:positive])}"

    {:ok, _live} = Auth.create_token(raw_live, "mfdb-live", @dataset, ["read"], ws_b.id)
    {:ok, dead} = Auth.create_token(raw_dead, "mfdb-dead", @dataset, ["read"], ws_b.id)

    # Decay it. `Auth.verify_token/1` folds revoked / expired / unknown into one
    # `{:error, :unauthorized}`, so a revoked token is the exact input class.
    {:ok, _} = Auth.revoke_token(dead)

    # Bound first, then asserted on a boolean: `assert pattern = expr, msg`
    # silently DISCARDS the message (the match raises on its own), and this
    # particular message is the anti-vacuity guard for the whole file.
    dead_verifies? = match?({:ok, _}, Auth.verify_token(raw_dead))

    refute dead_verifies?,
           "precondition: the revoked bearer must NOT verify, or every arm below is vacuous"

    %{
      default_ws: default_ws,
      default_file: default_file,
      ws_b: ws_b,
      file_b: file_b,
      raw_live: raw_live,
      raw_dead: raw_dead
    }
  end

  # ── POSITIVE CONTROLS — the anti-vacuity proof ─────────────────────────────

  describe "ANTI-VACUITY: the listings are non-empty for the right inputs" do
    test "flat GET /media lists Default's seeded file for an anonymous caller",
         %{default_file: default_file} do
      ids = scoped_conn() |> get("/media") |> json_response(200) |> Map.get("files") |> ids()

      assert default_file.id in ids,
             "POSITIVE CONTROL FAILED: /media did not list the seeded Default file " <>
               "#{default_file.id}. Every 'no foreign rows' refutation in this file is " <>
               "VACUOUS until this passes (usual cause: the fixture lacks dataset_id). " <>
               "Got: #{inspect(ids)}"
    end

    test "GET /v1/media/:dataset lists Default's seeded file for an anonymous caller",
         %{default_file: default_file} do
      ids = v1_asset_ids(scoped_conn() |> get("/v1/media/#{@dataset}"))

      assert default_file.id in ids,
             "POSITIVE CONTROL FAILED: /v1/media/#{@dataset} did not list the seeded " <>
               "Default file #{default_file.id}. Every refutation below is VACUOUS " <>
               "until this passes. Got: #{inspect(ids)}"
    end

    # A valid workspace-B bearer does NOT see Default's rows — token→workspace
    # derivation works. It does not see B's OWN rows either, for a reason that
    # is entirely separate from this fix and deliberately NOT repaired here:
    #
    #   `Media.Delivery.Search.resolve_dataset_id/2` computes
    #   `project_id = opts[:project_id] || default_project_id()`. On a flat
    #   route `AssignDefaultScope` deliberately leaves a DERIVED non-Default
    #   workspace project-less (its own moduledoc explains why pairing
    #   workspace A with the Default project would match zero rows), so the
    #   fallback resolves the DEFAULT project's dataset id and the query filters
    #   `m.dataset_id == <Default's production ds> AND m.workspace_id == <B>` —
    #   an empty intersection by construction.
    #
    # So the honest control for THIS change is the over-reach guard: a valid
    # bearer must not be turned into a 401. Filed separately as a follow-up.
    test "a VALID workspace-B bearer is served (not refused) and never sees Default's row",
         %{raw_live: raw_live, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_live) |> get("/v1/media/#{@dataset}")

      assert conn.status == 200,
             "OVER-REACH: a VALID bearer must not be refused. Got #{conn.status}: " <>
               inspect(conn.resp_body)

      refute default_file.id in v1_asset_ids(conn),
             "a valid B bearer saw Default's row — the scope is not being threaded"
    end
  end

  # ── task-6716af864218081b — the flat `/media` read block: the `scope "/media"`
  # that pipes through `[:api, :strict_bearer_media_read]` in BarkparkWeb.Router

  describe "flat /media — a decayed bearer must be refused, not tenant-swapped" do
    test "GET /media", %{raw_dead: raw_dead, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_dead) |> get("/media")

      assert conn.status == 401, decayed_msg("GET /media", conn, default_file.id)
      assert_unauthorized_envelope(conn)
    end

    test "GET /media/:id/meta", %{raw_dead: raw_dead, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_dead) |> get("/media/#{default_file.id}/meta")

      assert conn.status == 401, decayed_msg("GET /media/:id/meta", conn, default_file.id)
      assert_unauthorized_envelope(conn)
    end

    test "GET /media/files/*path", %{raw_dead: raw_dead, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_dead) |> get("/media/files/#{default_file.path}")

      assert conn.status == 401, decayed_msg("GET /media/files/*path", conn, default_file.id)

      refute conn.resp_body =~ "DEFAULT-TENANT-BYTES",
             "the refusal still handed over Default's BYTES"
    end

    test "GET /media/renditions/:id/:preset", %{raw_dead: raw_dead, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_dead) |> get("/media/renditions/#{default_file.id}/thumb")

      assert conn.status == 401,
             decayed_msg("GET /media/renditions/:id/:preset", conn, default_file.id)
    end
  end

  describe "flat /media — the controls a blanket 401 would break" do
    test "no Authorization header keeps the anonymous Default public read",
         %{default_file: default_file} do
      conn = get(scoped_conn(), "/media")

      assert conn.status == 200,
             "OVER-REACH: a header-less caller must keep its 200 — the public/browser " <>
               "read tier is a supported product surface. Got #{conn.status}."

      assert default_file.id in ids(json_response(conn, 200)["files"]),
             "OVER-REACH: the anonymous Default read lost its rows"
    end

    # See the note on the /v1 twin above: the row-level "B sees B's own file"
    # claim is blocked by a pre-existing dataset_id-resolution quirk that this
    # change neither causes nor repairs. The load-bearing guard is that a VALID
    # bearer keeps its 200.
    test "a VALID workspace-B bearer is served (not refused)",
         %{raw_live: raw_live, default_file: default_file} do
      conn = bearer(scoped_conn(), raw_live) |> get("/media")

      assert conn.status == 200,
             "OVER-REACH: a VALID bearer must not be refused. Got #{conn.status}: " <>
               inspect(conn.resp_body)

      refute default_file.id in ids(json_response(conn, 200)["files"]),
             "a valid B bearer saw Default's row"
    end

    test "a non-Bearer Authorization scheme is untouched", %{default_file: default_file} do
      conn =
        scoped_conn()
        |> put_req_header("authorization", "Preview some-preview-key")
        |> get("/media")

      assert conn.status == 200,
             "OVER-REACH: only a PRESENTED-but-unverifiable *Bearer* is refused; a " <>
               "non-Bearer scheme must pass through as before. Got #{conn.status}."

      assert default_file.id in ids(json_response(conn, 200)["files"])
    end
  end

  # ── task-79e10984bbb23734 — the flat `/v1/media` block: the `scope "/v1/media"`
  # that pipes through `[:api, :strict_bearer_media_read]` in BarkparkWeb.Router

  describe "flat /v1/media — a decayed bearer must be refused on all ten routes" do
    test "the nine GETs", %{raw_dead: raw_dead, default_file: default_file} do
      for path <- [
            "/v1/media/#{@dataset}",
            "/v1/media/#{@dataset}/#{default_file.id}",
            "/v1/media/#{@dataset}/#{default_file.id}/relations",
            "/v1/media/#{@dataset}/search?q=a",
            "/v1/media/#{@dataset}/search/suggestions?q=a",
            "/v1/media/#{@dataset}/collections",
            "/v1/media/#{@dataset}/collections/#{Ecto.UUID.generate()}",
            "/v1/media/#{@dataset}/collections/#{Ecto.UUID.generate()}/assets",
            "/v1/media/#{@dataset}/share/some-share-token"
          ] do
        conn = bearer(scoped_conn(), raw_dead) |> get(path)

        assert conn.status == 401, decayed_msg("GET #{path}", conn, default_file.id)
      end
    end

    test "the canonical 401 envelope on the /v1/media index", %{raw_dead: raw_dead} do
      conn = bearer(scoped_conn(), raw_dead) |> get("/v1/media/#{@dataset}")
      assert_unauthorized_envelope(conn)
    end

    test "the POST write leg — no interaction row may be stamped for Default",
         %{raw_dead: raw_dead, default_ws: default_ws} do
      parent = seed_search_event!(default_ws)
      before = interaction_count(default_ws)

      conn =
        bearer(scoped_conn(), raw_dead)
        |> post("/v1/media/#{@dataset}/search/interaction", %{
          "queryEventId" => parent.id,
          "objectId" => "asset-decayed-bearer",
          "type" => "click"
        })

      assert conn.status == 401,
             "WRITE LEG: a decayed bearer POSTed a search interaction and got " <>
               "#{conn.status}: #{inspect(conn.resp_body)}. The row is stamped with " <>
               "Default's workspace_id — misattributed telemetry on another tenant's " <>
               "media-search analytics partition (read back at " <>
               "GET /v1/media/:dataset/search/insights)."

      assert interaction_count(default_ws) == before,
             "WRITE LEG: the refusal did not prevent the write — an interaction row " <>
               "landed on the Default workspace anyway"
    end
  end

  describe "flat /v1/media — the controls a blanket 401 would break" do
    test "no Authorization header keeps the anonymous Default read",
         %{default_file: default_file} do
      conn = get(scoped_conn(), "/v1/media/#{@dataset}")

      assert conn.status == 200,
             "OVER-REACH: the header-less anonymous read must be untouched. " <>
               "Got #{conn.status}."

      assert default_file.id in v1_asset_ids(conn),
             "OVER-REACH: the anonymous Default read lost its rows"
    end

    test "an anonymous caller can still POST an interaction (unchanged, by design)",
         %{default_ws: default_ws} do
      parent = seed_search_event!(default_ws)

      conn =
        post(scoped_conn(), "/v1/media/#{@dataset}/search/interaction", %{
          "queryEventId" => parent.id,
          "objectId" => "asset-anonymous",
          "type" => "click"
        })

      assert conn.status == 200,
             "OVER-REACH: the header-less anonymous interaction POST produces the SAME " <>
               "Default-attributed row the decayed bearer produced — which is exactly " <>
               "why that row is misattributed telemetry and NOT a privilege escalation. " <>
               "It must keep working. Got #{conn.status}: #{inspect(conn.resp_body)}"
    end

    test "a VALID workspace-B bearer is unaffected on the search route",
         %{raw_live: raw_live} do
      conn = bearer(scoped_conn(), raw_live) |> get("/v1/media/#{@dataset}/search?q=a")

      assert conn.status == 200,
             "OVER-REACH: a VALID bearer must not be refused. Got #{conn.status}: " <>
               inspect(conn.resp_body)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp ids(files) when is_list(files), do: Enum.map(files, & &1["id"])

  defp v1_asset_ids(conn) do
    conn
    |> json_response(200)
    |> get_in(["result", "assets"])
    |> Kernel.||([])
    |> ids()
  end

  # The canonical envelope `RequireToken.deny/2` emits — the SAME 401 every
  # other refusal in the API uses. Asserting the code (not just the status)
  # keeps this surface on one contract instead of inventing a second one.
  defp assert_unauthorized_envelope(conn) do
    body = json_response(conn, 401)

    assert get_in(body, ["error", "code"]) == "unauthorized",
           "expected the canonical unauthorized envelope, got: #{inspect(body)}"
  end

  defp decayed_msg(route, conn, default_id) do
    body = to_string(conn.resp_body)

    "TENANT SWAP BY CREDENTIAL DECAY on #{route}: a REVOKED workspace-B bearer was " <>
      "silently downgraded to anonymous and answered #{conn.status} out of the seeded " <>
      "DEFAULT workspace (Default's seeded file is #{default_id}). Revocation is " <>
      "unobservable to the caller. Body: " <>
      inspect(binary_part(body, 0, min(400, byte_size(body))))
  end

  defp ensure_dataset!(project, slug) do
    case Tenancy.get_dataset(project, slug) do
      nil ->
        {:ok, ds} = Tenancy.create_dataset(project, %{slug: slug, name: slug})
        ds

      ds ->
        ds
    end
  end

  # dataset_id is LOAD-BEARING: `Media.Delivery.Search.build_query/2` filters on
  # `m.dataset_id` authoritatively once a Dataset row resolves for the (project,
  # slug) pair — which `ensure_dataset!/2` just guaranteed. A fixture without it
  # is invisible to every listing, and the refutations go vacuous.
  defp media_file!(workspace, project, dataset, bytes) do
    suffix = System.unique_integer([:positive])
    path = "uploads/mfdb/#{suffix}.txt"
    full = Media.file_path(path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, bytes)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: Path.basename(path),
      original_name: Path.basename(path),
      path: path,
      mime_type: "text/plain",
      size: byte_size(bytes),
      dataset: @dataset,
      workspace_id: workspace.id,
      project_id: project.id,
      dataset_id: dataset.id
    })
    |> Repo.insert!()
  end

  # `Intelligence.do_record_interaction/4` refuses unless the referenced parent
  # is a `search` event on the same surface+scope, so the write leg needs one.
  defp seed_search_event!(workspace) do
    Repo.insert!(%Event{
      surface: "media",
      scope: @dataset,
      event_type: "search",
      query: "mfdb",
      query_normalized: "mfdb",
      workspace_id: workspace.id
    })
  end

  defp interaction_count(workspace) do
    Repo.aggregate(
      from(e in Event,
        where:
          e.surface == "media" and e.workspace_id == ^workspace.id and e.event_type != "search"
      ),
      :count
    )
  end
end
