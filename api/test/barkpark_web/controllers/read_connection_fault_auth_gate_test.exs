defmodule BarkparkWeb.ReadConnectionFaultAuthGateTest do
  @moduledoc """
  task-66ec6750399f649f — the AUTH-PATH storage read in `QueryController`,
  which sat outside its own action's rescue region on the two doors everyone
  believed were already covered.

  THE GAP A RESCUE-SHAPED AUDIT CANNOT SEE. `index/2` and `show/2` each HAVE a
  rescue region (`query_index/4`, `show_doc/5`), so both pass the predicate the
  previous two rounds of this work used — "does this action have a rescue?".
  But the gate they consult first,

      not (preview?(conn) or authed?(conn) or
             Content.schema_public?(type, dataset, scope_opts(conn)))

  is evaluated in the ACTION BODY, outside that region, and
  `Content.schema_public?/3` is a `Repo` read (`Content.Schema.get_schema/3`).
  A checkout refused at that one call still rendered an opaque 500. The unit is
  a storage READ, not an action.

  THE DERIVATION, stated because criterion 0 asks for it rather than for the
  filing's list. Every module-level `def` in `query_controller.ex`, classified
  by whether it reaches storage and whether that read is inside its action's
  region:

      index/2        auth leg  schema_public?/3   OUTSIDE -> now :index_auth
      show/2         auth leg  schema_public?/3   OUTSIDE -> now :doc_show_auth
      index/2        body      query_index!/4     inside  (:query_index)
      show/2         body      show_doc!/5        inside  (:doc_show)
      backlinks/2    auth leg  preview?/authed?   no storage (conn.assigns)
      related/2      auth leg  preview?/authed?   no storage
      counts/2       auth leg  preview?/authed?   no storage
      tag_browse/2   auth leg  preview?/authed?   no storage
      tag_docs/2     auth leg  preview?/authed?   no storage
      backlinks/related/counts/tag_browse/tag_docs bodies  inside (read_region/3)
      invalid_filter_op_for_test/1, normalize_filter_map_for_test/1  pure

  TWO sites, not three, and the filing's two were both right.

  WHY A RESTRUCTURE AND NOT A WRAP: the `cond` clause ORDERING implements
  existence-hiding, and moving or hoisting the call changes which branch
  answers first. The fix widens the gate's RESULT from two values to three and
  keeps the short-circuit literal; the ordering arms below prove the property
  survived.

  FOUR PROPERTIES, each able to fail independently:

    * **THE NAMED RETRYABLE 503** — `storage_unavailable` /
      `connection_unavailable`, never 500 `internal_error`, which
      `transient_refusal?/1` does not treat as transient.

    * **NO FAIL-OPEN INTO AN AUTHORIZATION VERDICT** — the sharp edge here,
      and sharper than at the list doors. A rescue that recovered into `false`
      would render a refused checkout as "this type is not public": a
      PERMANENT 404 manufactured from a transient fault. The 404 is a live,
      reachable answer on this exact request (proved by the companion arm that
      gets one with the seam disarmed), so "it is not the 404" is a real
      discrimination, not a tautology.

    * **THE RESCUE IS NARROW** — a `RuntimeError` at the identical seam still
      propagates, so a bug in the schema read stays distinguishable from a
      storage fault.

    * **EXISTENCE-HIDING SURVIVES** — private and nonexistent types still
      answer byte-identically to an anonymous caller; the 404 still BEATS the
      `?perspective` 400; an authed caller still gets the 400.

  Plus two CONTROL arms: the seam disarmed answers a clean 200, and an AUTHED
  caller with the seam ARMED still answers 200 — which proves the
  short-circuit is intact, i.e. the fix did not start charging every
  token-authed read a schema query it never used to pay for.

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """

  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-read-dbconn-auth-gate-token"
  @dataset "production"
  @fault_message "tcp recv: closed"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-read-dbconn-auth-gate", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
        @dataset,
        scope
      )

    doc_id = "dbconn-auth-gate-#{System.unique_integer([:positive])}"

    {:ok, _draft} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _doc} = Content.publish_document(doc_id, "post", @dataset, scope)

    on_exit(fn -> Application.delete_env(:barkpark, :reader_fault) end)

    %{scope: scope, doc_id: doc_id}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp arm!(site, module \\ DBConnection.ConnectionError, message \\ @fault_message) do
    Application.put_env(:barkpark, :reader_fault, {site, module, message})
  end

  # The path an ANONYMOUS caller takes, which is the ONLY caller that reaches
  # `schema_public?/3` — `preview?/1` and `authed?/1` short-circuit ahead of it.
  defp path_for(:index_auth, type, _doc_id), do: "/v1/data/query/#{@dataset}/#{type}?limit=1"
  defp path_for(:doc_show_auth, type, doc_id), do: "/v1/data/doc/#{@dataset}/#{type}/#{doc_id}"

  @doors [:index_auth, :doc_show_auth]

  for site <- @doors do
    describe "#{site} — the auth-path schema read outside its action's rescue region" do
      test "a DBConnection.ConnectionError answers 503 storage_unavailable/connection_unavailable",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site)

        {resp, log} = with_log(fn -> get(conn, path_for(site, "post", doc_id)) end)

        assert log =~ "the database connection was lost mid-read"
        assert resp.status == 503

        error = Jason.decode!(resp.resp_body)["error"]

        assert error["code"] == "storage_unavailable"
        assert error["reason"] == "connection_unavailable"

        # THE ASSERTION THAT REDDENS ON THE UNFIXED TREE: with the auth read
        # outside the region the raise reaches ErrorJSON as 500 internal_error
        # / "unknown error (DBConnection.ConnectionError)", which
        # transient_refusal?/1 does not treat as transient.
        refute error["code"] == "internal_error"
        refute to_string(error["message"]) =~ "unknown error"

        assert error["message"] =~ @fault_message
      end

      test "NO FAIL-OPEN INTO AN AUTHORIZATION VERDICT: never the 404 a non-public type gets, never a 200",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)

        # COMPANION, DISARMED: the 404 is a LIVE answer on this exact request
        # shape, so the refutation below discriminates rather than restating an
        # impossibility. `secret` is visibility: "private", so schema_public?/3
        # answers false and the gate renders its authorization verdict.
        Application.delete_env(:barkpark, :reader_fault)
        verdict = get(conn, path_for(site, "secret", doc_id))

        assert verdict.status == 404,
               "the private type must answer 404 with the seam disarmed, or the refutation " <>
                 "below is vacuous"

        arm!(site)

        {resp, _log} = with_log(fn -> get(conn, path_for(site, "post", doc_id)) end)

        refute resp.status == 404,
               "a refused checkout answered the SAME 404 a not-public type answers — a " <>
                 "storage fault was turned into an AUTHORIZATION VERDICT, which is worse " <>
                 "than the 500 it replaces"

        refute resp.status == 200,
               "a refused checkout answered 200 — the gate fell OPEN on a fault"

        refute resp.status == 403

        body = Jason.decode!(resp.resp_body)

        assert is_nil(body["result"]),
               "the refusal body carried a success shape — a caller may read it as a real answer"

        assert is_nil(body["count"])
        refute body["ok"] == true

        assert body["error"]["code"] == "storage_unavailable"
      end

      test "the FAULT arm itself hides existence: a public and a private type answer identically",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site)

        {public_resp, _} = with_log(fn -> get(conn, path_for(site, "post", doc_id)) end)
        {private_resp, _} = with_log(fn -> get(conn, path_for(site, "secret", doc_id)) end)

        {missing_resp, _} =
          with_log(fn -> get(conn, path_for(site, "no-such-type-here", doc_id)) end)

        # The fault is raised BEFORE the visibility flag is read, so the
        # refusal cannot be a function of it. If a future rewrite consulted
        # the schema first and only then faulted, the statuses would diverge
        # and this arm would red.
        assert public_resp.status == 503
        assert private_resp.status == 503
        assert missing_resp.status == 503

        codes =
          [public_resp, private_resp, missing_resp]
          |> Enum.map(&Jason.decode!(&1.resp_body)["error"]["code"])
          |> Enum.uniq()

        assert codes == ["storage_unavailable"],
               "the fault refusal differed by type visibility/existence — the 503 became an " <>
                 "existence probe"
      end

      test "a NON-connection exception at the identical seam is UNCHANGED",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site, RuntimeError, "not a connection fault")

        # The rescue matches DBConnection.ConnectionError and NOTHING wider —
        # not a bare rescue, not Ecto.QueryError — so a bug in the schema read
        # stays distinguishable from the storage fault this row exists to name.
        assert_raise RuntimeError, "not a connection fault", fn ->
          get(conn, path_for(site, "post", doc_id))
        end
      end

      test "CONTROL: with the seam DISARMED the same anonymous request is a clean 200",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        Application.delete_env(:barkpark, :reader_fault)

        resp = get(conn, path_for(site, "post", doc_id))

        assert resp.status == 200

        refute is_nil(Jason.decode!(resp.resp_body)["result"]),
               "the door answered 200 without its success shape — the arms above would pass " <>
                 "on a door broken for every request"
      end

      test "CONTROL: the SHORT-CIRCUIT is intact — an AUTHED caller with the seam ARMED still gets 200",
           %{conn: conn, doc_id: doc_id} do
        site = unquote(site)
        arm!(site)

        # `preview?(conn) or authed?(conn)` short-circuits ahead of
        # schema_public?/3 in the original expression, and public_gate/5 keeps
        # that literally. If the fix had hoisted the schema read above the
        # cond, this seam would fire for a token-authed caller too — a new
        # Repo query on every authed read, and this arm would red with a 503.
        resp = conn |> authed() |> get(path_for(site, "post", doc_id))

        assert resp.status == 200,
               "an authed caller paid the auth-path schema read it never used to pay — the " <>
                 "short-circuit was lost"
      end
    end
  end

  # ── THE ORDERING THE RESTRUCTURE HAD TO PRESERVE ─────────────────────────
  #
  # These arms do NOT depend on the fault seam. They are the property the row
  # says must be proved rather than assumed, and they are pinned elsewhere too:
  #   * query_controller_perspective_test.exs — "an ANONYMOUS caller on a
  #     private type gets 404, not the 400 — the refusal is never an existence
  #     probe" (show/2)
  #   * read_perspective_strict_test.exs — "the refusal is never an existence
  #     probe: unknown id + bogus perspective is 404" (the sibling doctrine)
  #   * public_read_private_type_clamp_test.exs — the public-read tier 404s
  # A duplicate here on purpose: those files would not red if THIS controller's
  # ordering moved and theirs happened to cover a different door.
  describe "EXISTENCE-HIDING (no fault seam armed)" do
    setup do
      Application.delete_env(:barkpark, :reader_fault)
      :ok
    end

    test "an anonymous caller cannot distinguish a PRIVATE type from a NONEXISTENT one",
         %{conn: conn, doc_id: doc_id} do
      for {label, path} <- [
            {"query/private", "/v1/data/query/#{@dataset}/secret?limit=1"},
            {"query/missing", "/v1/data/query/#{@dataset}/no-such-type-here?limit=1"},
            {"doc/private", "/v1/data/doc/#{@dataset}/secret/#{doc_id}"},
            {"doc/missing", "/v1/data/doc/#{@dataset}/no-such-type-here/#{doc_id}"}
          ] do
        resp = get(conn, path)

        assert resp.status == 404, "#{label} answered #{resp.status}, not 404"
      end

      private = get(conn, "/v1/data/query/#{@dataset}/secret?limit=1")
      missing = get(conn, "/v1/data/query/#{@dataset}/no-such-type-here?limit=1")

      assert Jason.decode!(private.resp_body)["error"]["code"] ==
               Jason.decode!(missing.resp_body)["error"]["code"],
             "the two refusals differ by error code — an existence probe"
    end

    test "the existence-hiding 404 still BEATS the ?perspective 400 on both doors",
         %{conn: conn, doc_id: doc_id} do
      # The clause order is the mechanism: the auth answer is decided before
      # unsupported_read_perspective/1 is ever evaluated. Flip the two and an
      # anonymous caller learns that `secret` exists, because a nonexistent
      # type would have to answer the same 400.
      for path <- [
            "/v1/data/query/#{@dataset}/secret?perspective=zzzbogus",
            "/v1/data/doc/#{@dataset}/secret/#{doc_id}?perspective=zzzbogus"
          ] do
        assert get(conn, path).status == 404,
               "#{path} answered the perspective 400 before the existence-hiding 404"
      end
    end

    test "CONTROL: the ?perspective 400 is still reachable for a caller past the gate",
         %{conn: conn, doc_id: doc_id} do
      # Without this, the arm above passes on a controller that lost the
      # perspective check entirely.
      for path <- [
            "/v1/data/query/#{@dataset}/post?perspective=zzzbogus",
            "/v1/data/doc/#{@dataset}/post/#{doc_id}?perspective=zzzbogus"
          ] do
        resp = conn |> authed() |> get(path)

        assert resp.status == 400, "#{path} answered #{resp.status}, not the perspective 400"

        assert Jason.decode!(resp.resp_body)["error"]["details"]["received"] == "zzzbogus"
      end
    end
  end

  # ── BLAST RADIUS, PROVEN RATHER THAN ASSERTED IN PROSE ───────────────────

  describe "blast radius" do
    test "the UNTOUCHED door GET /v1/graph/orphans still raises, exactly as before",
         %{conn: conn} do
      arm!(:graph_orphans)

      # This change adds two seams inside QueryController and NOTHING else.
      # `graph_orphans` in TasksController is deliberately still unwrapped —
      # a rig that reds everything would red this too.
      assert_raise DBConnection.ConnectionError, fn ->
        conn |> authed() |> get("/v1/graph/orphans")
      end
    end
  end
end
