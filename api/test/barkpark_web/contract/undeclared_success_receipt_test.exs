defmodule BarkparkWeb.UndeclaredSuccessReceiptTest do
  @moduledoc """
  task-ef7f93eebba52fd3 — the three receipt sites where a failure path was said
  to reach the same `ok: true` as success with nothing on the record declaring
  it. Derived at base `9a5936e09` by running
  `elixir scripts/pds-elixir-receipt-census.exs --sites`.

  THE SITES ARE NAMED BY SYMBOL, NOT BY LINE, and the three below were converted
  from `file.ex:<line>` form after one of them rotted (task-2e0ad8b4e06b9b40). A
  line number is stale the moment anything is inserted above it; every one of
  these three had something inserted above it, by the very SPELLING, DELIBERATE
  comment blocks this suite's declaration arms require. A symbol moves with the
  code and cannot rot.

  WHY THE ROT WAS SILENT FOR SO LONG — the mechanism, written here because the
  lane that finally trips the citation guard is almost never the lane that broke
  the citation. `tooling/doc-truth/verify-docs.mjs` confirms a citation when ANY
  harvested anchor word sits within ±3 lines of the cited line
  (`verifyLinerefAgainst/2`, `const WINDOW = 3`). So an INCIDENTAL token — a
  string literal, a comment word — that happens to land near a badly-wrong line
  keeps that citation green. When an unrelated diff shifts the incidental token
  out of the window, the guard reds, and it looks like that diff broke the
  citation. It did not: it stopped HIDING a citation that was already wrong. The
  window is not widened to fix this — widening confirms every citation against a
  neighbour — so the repair is always to drop the number and keep the symbol.

  WHAT THE CENSUS ACTUALLY SAYS, and what this suite pins:

    * `SearchController.delete_search_synonym/2` /
      `V1.MediaController.delete_search_synonym/2` —
      `CATCH-ALL-TO-SUCCESS, 0 undeclared of 3 fired` — it read `2 undeclared of
      3 fired` for two waves AFTER these rulings shipped, because a code comment
      does not reach the census's `@declared` register; the rows landed under
      task-477972989335da51. The arm fires because the
      clause head is a discarding variable (`_ws_id`) whose body renders
      `ok: true`. That head is the NON-NIL half of the tenancy split, not a
      failure sink, and `Synonyms.delete/4` is `:ok | {:error, :not_found}` —
      every failure it can produce is answered 404 by the clause beside the
      receipt. Ruling: DECLARED-HONEST, declared in the code.

    * `AuthController.request_magic_link/2` — the `token_mint_failed` arm falls through to the
      SAME anti-enumeration `ok: true`. Ruling: DECLARED-HONEST (PURE ECHO),
      declared in the code. The merge is required, not tolerated: a mint failure
      is reachable ONLY for an address that resolved to a user, so a
      distinguishable receipt would be an account-existence oracle.

  TWO ARMS PER SITE, on purpose.

    * BEHAVIOURAL — the arm that reds if the declaration ever stops being TRUE:
      a failing DELETE must answer 404, and the three magic-link outcomes must
      stay byte-identical. These red on the code, not on the comment.

    * DECLARATION — the arm that reds if the ruling is deleted: the basis token
      must still occur inside the function that carries it. Honest label, same
      as `BarkparkWeb.AuthNotificationWithholdTest`: this is a structural
      tripwire, not a behavioural proof. It exists because "undeclared" was the
      defect, so the declaration is itself a shipped artefact with a guard.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonym

  @ds "production"
  @password "correct-horse-battery"

  @search_source "lib/barkpark_web/controllers/search_controller.ex"
  @media_source "lib/barkpark_web/controllers/v1/media_controller.ex"
  @auth_source "lib/barkpark_web/controllers/auth_controller.ex"

  setup do
    {default_ws, _project} = ensure_default_scope!()
    {:ok, default_ws: default_ws}
  end

  defp insert_admin_token!(workspace_id) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "receipt-census-admin",
        dataset: @ds,
        permissions: ["read", "write", "admin"],
        workspace_id: workspace_id
      })
      |> Repo.insert()

    raw
  end

  defp auth(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp seed_synonym!(surface, workspace_id) do
    {:ok, row} =
      %Synonym{}
      |> Synonym.changeset(%{
        surface: surface,
        scope: @ds,
        from_query: "seeded-from-#{System.unique_integer([:positive])}",
        to_query: "seeded-to",
        kind: "one_way",
        source: "manual",
        workspace_id: workspace_id
      })
      |> Repo.insert()

    row
  end

  # Read a controller source and return only the body of ONE named def, so a
  # token assertion cannot be satisfied by an unrelated line elsewhere in a
  # 3,000-line controller.
  defp def_body!(path, needle) do
    lines = path |> File.read!() |> String.split("\n")
    start = Enum.find_index(lines, &String.contains?(&1, needle))

    assert start, "#{path}: could not find the def line containing #{inspect(needle)}"

    indent = "  "

    rest = Enum.drop(lines, start + 1)

    body =
      Enum.take_while(rest, fn line -> line != indent <> "end" end)

    Enum.join(body, "\n")
  end

  # ── SITES 1 + 2 — BEHAVIOURAL ────────────────────────────────────────────────
  #
  # The declaration's load-bearing claim is "no failure reaches this receipt".
  # These reds the moment that stops holding — a `{:error, :not_found}` arm
  # deleted, or `Synonyms.delete/4` widened to return something the case would
  # have to absorb.

  describe "a failing synonym DELETE never reaches the ok: true receipt" do
    test "documents: an unknown id is 404, not ok: true", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)

      conn = auth(raw) |> delete("/v1/data/search/#{@ds}/synonyms/#{Ecto.UUID.generate()}")

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
      refute body["ok"] == true
    end

    test "documents: a non-UUID id is 404, not ok: true and not a 500", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)

      conn = auth(raw) |> delete("/v1/data/search/#{@ds}/synonyms/not-a-uuid")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "media: an unknown id is 404, not ok: true", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)

      conn = auth(raw) |> delete("/v1/media/#{@ds}/search/synonyms/#{Ecto.UUID.generate()}")

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
      refute body["ok"] == true
    end

    test "media: a non-UUID id is 404, not ok: true", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)

      conn = auth(raw) |> delete("/v1/media/#{@ds}/search/synonyms/not-a-uuid")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # THE QUIET ARM. The declaration must not have cost the honest 200 — a guard
  # that reds on the success path would be a worse defect than the silence.
  describe "a genuine synonym DELETE still gets its ok: true" do
    test "documents: the seeded row is deleted and the receipt says ok", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)
      seeded = seed_synonym!("documents", ws.id)

      conn = auth(raw) |> delete("/v1/data/search/#{@ds}/synonyms/#{seeded.id}")

      assert json_response(conn, 200)["ok"] == true
      refute Repo.get(Synonym, seeded.id)
    end

    test "media: the seeded row is deleted and the receipt says ok", %{default_ws: ws} do
      raw = insert_admin_token!(ws.id)
      seeded = seed_synonym!("media", ws.id)

      conn = auth(raw) |> delete("/v1/media/#{@ds}/search/synonyms/#{seeded.id}")

      assert json_response(conn, 200)["ok"] == true
      refute Repo.get(Synonym, seeded.id)
    end
  end

  # ── SITE 3 — ANTI-ENUMERATION, the criterion-2 arm ───────────────────────────
  #
  # THIS IS THE TEST THAT REDS IF THE FIX LEAKS ACCOUNT EXISTENCE. Any change to
  # `request_magic_link/2` that gives the mint-failure arm its own receipt must
  # give one of these two a different status or a different body.

  describe "request-magic-link stays a single indistinguishable receipt" do
    test "a registered and an unregistered address are byte-identical", %{conn: conn} do
      {:ok, _u} = Accounts.register_user(%{email: "known@example.com", password: @password})

      known =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/auth/request-magic-link",
          Jason.encode!(%{email: "known@example.com"})
        )

      unknown =
        scoped_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/v1/auth/request-magic-link",
          Jason.encode!(%{email: "ghost@example.com"})
        )

      assert known.status == unknown.status
      assert known.resp_body == unknown.resp_body
      assert json_response(known, 200) == %{"ok" => true}
    end

    # The mint-failure arm is a mid-flight race no HTTP request can force without
    # fabricating a seam (the same honest label `AuthNotificationWithholdTest`
    # carries). So the third outcome is pinned STRUCTURALLY: the function must
    # render exactly ONE response, reached by all three arms. Splitting the
    # failure receipt out reds this immediately.
    test "request_magic_link/2 renders exactly one response, outside the case" do
      body = def_body!(@auth_source, ~s|def request_magic_link(conn, %{"email" => email})|)

      responders =
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.filter(&(String.contains?(&1, "json(conn") or String.contains?(&1, "error(conn")))

      assert responders == ["json(conn, %{ok: true})"],
             "request_magic_link/2 must reach ONE receipt from all three arms; found: " <>
               inspect(responders)
    end

    test "all three arms of build_login_token/1 are still named, none collapsed" do
      body = def_body!(@auth_source, ~s|def request_magic_link(conn, %{"email" => email})|)

      assert body =~ "{:ok, token, user} ->"
      assert body =~ ":no_user ->"
      assert body =~ "{:error, changeset} ->"
      refute body =~ ~r/\n\s+_ ->/, "a catch-all arm would re-collapse the distinction"
    end
  end

  # ── THE DECLARATIONS THEMSELVES ──────────────────────────────────────────────
  #
  # HONEST LABEL: structural. "Undeclared" WAS the defect, so the declaration is
  # the shipped artefact and this is its tripwire. It reds when a ruling is
  # deleted or silently moved to another function.

  describe "every one of the three sites carries its ruling in the code" do
    test "search_controller.delete_search_synonym/2 declares CATCH-ALL-TO-SUCCESS" do
      body = def_body!(@search_source, ~s|def delete_search_synonym(conn, %{"dataset" => dataset|)

      assert body =~ "CATCH-ALL-TO-SUCCESS — DECLARED-HONEST"
      assert body =~ "THE HEAD IS NOT A FAILURE SINK"
      assert body =~ "NO FAILURE REACHES THIS RECEIPT"
    end

    test "v1/media_controller.delete_search_synonym/2 declares CATCH-ALL-TO-SUCCESS" do
      body = def_body!(@media_source, ~s|def delete_search_synonym(conn, %{"dataset" => dataset|)

      assert body =~ "CATCH-ALL-TO-SUCCESS — DECLARED-HONEST"
      assert body =~ "THE HEAD IS NOT A FAILURE SINK"
      assert body =~ "NO FAILURE REACHES THIS RECEIPT"
    end

    test "auth_controller.request_magic_link/2 declares the PURE ECHO merge" do
      body = def_body!(@auth_source, ~s|def request_magic_link(conn, %{"email" => email})|)

      assert body =~ "PURE ECHO — DECLARED-HONEST"
      assert body =~ "WHY IT MUST MERGE"
      assert body =~ "WHERE THE DISTINCTION LIVES INSTEAD"
    end
  end
end
