defmodule BarkparkWeb.Integration.HttpConditionalPolicyTest do
  @moduledoc """
  The conditional-request contract on the two ETag-bearing read surfaces
  (http-edge-truth W2 slice 4, charter D6).

  ## The defect, as observed live on prod before the fix

  `GET /v1/data/doc/production/task/task-f69b2c1a31b71ec0` and the SAME url with
  `?fields=title` both answered with the strong validator
  `"b75c68f15a031a542076615145dbe70c"` — over a 10,174-byte body and a 630-byte
  body respectively. Replaying the first ETag against the `?fields=` url then
  answered **304 with an empty body**: the server told a caller holding the full
  document that it was a valid answer to a projected request. A bogus ETag on
  the same url answered 200/630, so the probe could see both outcomes.

  The cause is structural, not a typo. `doc_etag/1` returns the document's bare
  `_rev`, and `list_etag/3` folds `dataset|type|_id:_rev` — while the BODY is a
  function of three more things none of those inputs touch:

    * `?fields=` — `project_fields/2` keeps every `_`-prefixed system key, so
      `_id` and `_rev` survive a projection completely unchanged;
    * `?expand=` — reference hydration;
    * `?resolve=tasks` — task-block snapshotting;

  and, on the principal axis, `Envelope.render/3` picks the visible FIELD SET
  out of the `CallerContext` (an admin token sets `is_admin: true` and sees
  `private` / `readable_by` fields). RFC 9110 §8.8.1 requires a strong validator
  to change whenever the representation changes; none of these move it.

  ## The fix under test

  The ETag header — and with it the 304 branch — is withdrawn whenever the
  response is SHAPED (`fields`/`expand`/`resolve`) or PRINCIPAL-BOUND (a token
  or a non-anonymous caller context). `Vary: Authorization` rides every query
  response and the capabilities manifest, merged into any `vary` already there.

  Note the direction, which is what makes this safe to ship (charter D1): every
  arm here REMOVES cacheability. A request that used to 304 now gets a full 200.
  The failure mode of a mistake in this file is wasted bytes, never a stale or
  cross-principal body.

  ## Mutation proofs

  Each pin below names the exact edit that restores the defect and reds it. They
  are real, not decorative — `"the shaped request cannot be answered 304 from an
  unshaped validator"` IS the prod observation above, reproduced.

  `capabilities` gets a Vary pin only: its ETag is already correct
  (`Capabilities.etag_for/1` hashes the PROJECTED, tier-filtered body, so an
  anon manifest and an admin manifest cannot collide). It is pinned here anyway
  so a future refactor that moves the digest off the projected body reds.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "http_conditional_policy_test"
  @type_name "post"
  @doc_id "hcp-00001"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Post",
          "visibility" => "public",
          "fields" => []
        },
        @ds
      )

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => @doc_id, "title" => "conditional policy", "body" => "the long field"},
        @ds
      )

    {:ok, _} = Content.publish_document(@doc_id, @type_name, @ds)

    :ok
  end

  defp doc_path(qs \\ ""), do: "/v1/data/doc/#{@ds}/#{@type_name}/#{@doc_id}" <> qs
  defp list_path(qs \\ ""), do: "/v1/data/query/#{@ds}/#{@type_name}" <> qs

  defp etag_of(conn), do: get_resp_header(conn, "etag")

  defp vary_of(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  defp read_token! do
    raw = "tok-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "hcp-read", @ds, ["read"])
    raw
  end

  describe "the baseline that keeps every other assertion honest" do
    # Without this, every "no etag" pin below could be passing because the
    # route is broken, the fixture is invisible, or the seed never published.
    test "an ANONYMOUS, UNSHAPED read still gets a validator and still 304s", %{conn: conn} do
      conn = get(conn, doc_path())
      assert conn.status == 200
      assert [etag] = etag_of(conn)
      assert etag != ""

      replay = get(put_req_header(build_conn(), "if-none-match", etag), doc_path())
      assert replay.status == 304
      assert replay.resp_body == ""
    end

    test "the seeded document really is readable and really has a body to project", %{conn: conn} do
      full = json_response(get(conn, doc_path()), 200)
      projected = json_response(get(build_conn(), doc_path("?fields=title")), 200)

      assert full != projected,
             "fixture is vacuous: ?fields= did not change the body, so nothing here is a projection test"
    end
  end

  describe "SHAPED responses carry no validator (D6 — representation-fixed by omission)" do
    # MUTATION PROOF for all three: delete `@shaping_params` from
    # `conditional_safe?/1` (or make it return `true` unconditionally) and every
    # test in this block reds — the header comes back.
    for {label, qs} <- [
          {"?fields= projection", "?fields=title"},
          {"?expand= hydration", "?expand=author"},
          {"?resolve=tasks snapshotting", "?resolve=tasks"}
        ] do
      test "single doc — #{label} suppresses the etag" do
        conn = get(build_conn(), doc_path(unquote(qs)))
        assert conn.status == 200

        assert etag_of(conn) == [],
               "a shaped representation advertised a validator keyed on _rev alone"
      end

      test "list — #{label} suppresses the etag" do
        conn = get(build_conn(), list_path(unquote(qs)))
        assert conn.status == 200
        assert etag_of(conn) == []
      end
    end

    test "and a shaped request is NOT answered 304 from an unshaped validator", %{conn: conn} do
      # THIS IS THE PROD DEFECT, reproduced. Pre-fix this returned 304 + empty
      # body; the caller's full 10KB document stood in for a 630-byte projection.
      [etag] = etag_of(get(conn, doc_path()))

      shaped =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get(doc_path("?fields=title"))

      assert shaped.status == 200,
             "the server answered a PROJECTED request 304 from a FULL representation's validator"

      body = json_response(shaped, 200)
      refute body == json_response(get(build_conn(), doc_path()), 200)
    end
  end

  describe "PRINCIPAL-BOUND responses carry no validator" do
    # MUTATION PROOF: drop the `anonymous_principal?/1` conjunct from
    # `conditional_safe?/1` and both tests red.
    test "a token-bearing read gets no etag, even unshaped" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> read_token!())
        |> get(doc_path())

      assert conn.status == 200

      assert etag_of(conn) == [],
             "a principal-bound body advertised a validator that folds no principal"
    end

    test "a token-bearing read cannot be answered 304 from an anonymous validator" do
      [anon_etag] = etag_of(get(build_conn(), doc_path()))

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> read_token!())
        |> put_req_header("if-none-match", anon_etag)
        |> get(doc_path())

      assert conn.status == 200,
             "an authenticated caller was handed a 304 minted for the anonymous representation"
    end
  end

  describe "Vary: Authorization (D6 — defense in depth for the shared-cache hop)" do
    test "rides the query response that KEEPS its etag", %{conn: conn} do
      conn = get(conn, doc_path())
      assert "authorization" in vary_of(conn)
    end

    test "rides the query response that DROPS its etag" do
      conn = get(build_conn(), doc_path("?fields=title"))
      assert "authorization" in vary_of(conn)
    end

    test "rides the list route", %{conn: conn} do
      assert "authorization" in vary_of(get(conn, list_path()))
    end

    test "rides GET /v1/capabilities, whose body is tier-keyed", %{conn: conn} do
      conn = get(conn, "/v1/capabilities")
      assert conn.status == 200
      assert "authorization" in vary_of(conn)
    end

    # MUTATION PROOF: replace the merge in `put_vary_authorization/1` with a bare
    # `put_resp_header(conn, "vary", "authorization")` and this reds — that is
    # the whole point of merging rather than setting.
    test "and does not clobber a vary another plug already set" do
      conn =
        build_conn()
        |> Plug.Conn.put_resp_header("vary", "origin")
        |> get(doc_path())

      vary = vary_of(conn)
      assert "authorization" in vary
      assert "origin" in vary, "merging dropped a pre-existing vary directive"
    end
  end

  describe "capabilities keeps its correct, tier-keyed validator" do
    test "same tier still round-trips to a 304", %{conn: conn} do
      first = get(conn, "/v1/capabilities")
      assert [etag] = etag_of(first)

      replay =
        build_conn()
        |> put_req_header("if-none-match", etag)
        |> get("/v1/capabilities")

      assert replay.status == 304
    end

    # The property that makes capabilities SAFE where query was not: the digest
    # is taken over the projected body, so the tier is inside the validator.
    # MUTATION PROOF: compute `etag_for/1` over the pre-projection superset and
    # this reds.
    test "a different tier yields a different validator", %{conn: conn} do
      [anon_etag] = etag_of(get(conn, "/v1/capabilities"))

      admin_raw = "tok-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(admin_raw, "hcp-admin", @ds, ["read", "write", "admin"])

      [admin_etag] =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> admin_raw)
        |> get("/v1/capabilities")
        |> etag_of()

      refute anon_etag == admin_etag,
             "the tier-keyed manifest collapsed to one validator across two tiers"
    end
  end
end
