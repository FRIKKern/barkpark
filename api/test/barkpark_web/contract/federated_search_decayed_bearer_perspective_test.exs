defmodule BarkparkWeb.Contract.FederatedSearchDecayedBearerPerspectiveTest do
  @moduledoc """
  RESIDUE PIN — the half of the `?perspective=drafts` silent pin that the
  `OptionalToken` strict-on-presented fix (PR #14318) does NOT reach.

  THE PIPELINE SPLIT, which is the whole point of this file:

    * `GET /v1/data/query/:ds/:type` rides `[:api, :api_grant_read]` — the flat
      `/v1/data` read pipeline the parent fix mounts `strict_on_presented: true`
      on. A presented-but-unverifiable bearer will 401 there before it ever
      reaches the perspective logic. SUBSUMED.
    * `GET /v1/search/:dataset` (`FederatedSearchController`) rides the
      "Federated discovery" scope (api/lib/barkpark_web/router.ex). It rode
      BARE `:api` when this file was written; `Plugs.PublicRead` — the plug
      that turns a drafts request into a LOUD 403 — is mounted on
      `:api_grant_read`, `:shared_docs_api` and `:require_token`, never on
      bare `:api`.

  So on the federated route a caller whose perspective request cannot be
  honoured is still silently pinned to `:published` by
  `BarkparkWeb.AnonPerspective`, and the envelope echo is what tells it so.

  THE ASYMMETRY WAS WIDER THAN WHEN THIS FILE WAS WRITTEN, AND IS NOW CLOSED.
  #14318 merged nine seconds before the commit that added the flat-route
  contrast test, so neither could see the other: that test asserted the silent
  200 the flat route used to give a decayed bearer, and it went red on main the
  moment the two landed together. #14433 restated it against the behaviour that
  actually shipped — `/v1/data/query` refusing 401 in the open while the
  federated route still answered 200 in silence.

  ## UPDATE (task-f7230d4a500fffb6): THE DECAYED HALF IS NOW REFUSED HERE TOO

  That remaining asymmetry WAS the defect, and it is now fixed: the Federated
  discovery scope pipes through `[:api, :api_strict_bearer]`, whose
  `OptionalToken, strict_on_presented: true` refuses a presented-but-
  unverifiable bearer with 401 — closing a tenant swap in which a revoked
  workspace-B bearer was served the seeded **Default** workspace's rows at 200.

  This file's decayed-credential cells anticipated their own obsolescence, in
  these words: "if such a gate ever lands on bare `:api`, this half starts
  401ing and its RED goes away." It has landed. Those cells now assert the
  REFUSAL rather than the clamp — for that population the strict gate SUBSUMES
  the perspective question, because the request never reaches the perspective
  logic at all. The two read surfaces now agree: both refuse a decayed bearer.

  Nothing else about this file's thesis moves. The envelope echo is still the
  finding and is still load-bearing — it is now carried entirely by the
  populations no bearer gate can reach: the VALID `public-read` token
  (population 2 below) and the ANONYMOUS caller. Every echo assertion that used
  a garbage bearer now uses one of those, so the coverage is preserved rather
  than deleted.

  THE SIGNAL ASYMMETRY WAS THE FINDING, stated precisely rather than maximally.
  `QueryController` echoes the perspective it ACTUALLY used at
  `result.perspective`, so a caller on `/v1/data/query` could detect the
  downgrade from the response envelope alone. That echo is still pinned here,
  now via an ANONYMOUS caller — the population the strict-bearer arm
  deliberately leaves untouched, and therefore the one that can still reach
  `QueryController` to demonstrate it.
  `FederatedSearchController`'s body was
  `%{query, surfaces, results, searchEventId, ms}` — no perspective key at any
  level. Same downgrade, same instant, one route told you and the other did
  not.

  FIXED, and this file is now the regression pin. The federated envelope
  carries a root-level `perspective` echo using the SAME key name and the same
  `to_string/1` shape `QueryController` already uses, so the two read surfaces
  agree rather than this route inventing a third convention. SIGNAL ONLY — the
  clamp is untouched, still silent, and still fails closed, which the sibling
  tests here keep pinned. The echo is DYNAMIC, not a constant `"published"`:
  the honoured-perspective cell is pinned below precisely so a hardcoded
  literal could not satisfy this file.

  HONEST QUALIFIER, pinned below so nobody reads this file as claiming more
  than it proves: the federated hits ALREADY carried a per-row `_draft`
  boolean, so a caller that inspects every row could always infer the
  downgrade — but only while the result set is NON-EMPTY. That is exactly why
  the row flag was never a substitute for an envelope echo: an empty page
  carries no row-level indicator whatsoever, so an instrument could not
  distinguish "no drafts matched" from "drafts were never searched". The
  envelope echo is what closes that hole, and the zero-row case is pinned below
  to prove it.

  TWO POPULATIONS, and the second is the durable one:

    1. DECAYED credential (garbage/revoked/expired bearer). WAS silently
       downgraded to anonymous by `OptionalToken`, then pinned. NOW REFUSED 401
       by the `:api_strict_bearer` overlay (task-f7230d4a500fffb6) — the
       population is gone from the perspective question entirely, and its cells
       below pin the refusal instead.
    2. VALID credential with insufficient permission (a `public-read` token).
       `Auth.verify_token/1` SUCCEEDS, so NO bearer gate can ever refuse it.
       `AnonPerspective.anon_pinned?/1` pins it exactly like an anonymous
       caller, and the envelope still says nothing. This half survives any
       bearer-strictness fix, which is why it is pinned separately below.

  The same `public-read` token is refused LOUDLY (403 "perspective not allowed")
  on `/v1/data/query`, because `:api_grant_read` mounts `Plugs.PublicRead`. Same
  credential, same question, same instant: one route refuses in the open, the
  other answers 200 in silence. That asymmetry is pinned here as a passing
  contrast test.

  Prior coverage, so this file is not read as duplicating it:
  `test/barkpark_web/integration/public_read_search_matrix_test.exs` pins that a
  mixed public-read token is silently ROW-clamped on this route. It does not
  assert anything about the response ENVELOPE, which is the gap this file pins.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @type_name "fsdpost"
  @probe "wombatsearch"
  @garbage "garbage-not-a-real-token"

  setup do
    {ws, project} = ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "FSDPost", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # A PUBLISHED row and a DRAFT-ONLY row, both matching the probe query.
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "fsd-pub", "title" => "#{@probe} Live Row"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("fsd-pub", @type_name, @dataset, scope)

    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => "fsd-draft", "title" => "#{@probe} Secret Draft"},
        @dataset,
        scope
      )

    admin_raw = "fsd-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(admin_raw, "fsd-admin", @dataset, ["read", "write", "admin"], ws.id)

    # A VALID credential with insufficient permission. `verify_token/1` SUCCEEDS
    # on this one, so no strict-bearer gate can ever refuse it — this is the
    # population that survives the parent fix entirely.
    pubread_raw = "fsd-pubread-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(pubread_raw, "fsd-pubread", @dataset, ["public-read"], ws.id)

    {:ok, admin: admin_raw, pubread: pubread_raw}
  end

  defp bearer(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp federated_body(conn, url) do
    resp = get(conn, url)
    assert resp.status == 200, "expected 200 on the federated route, got #{resp.status}"
    Jason.decode!(resp.resp_body)
  end

  defp hits(body), do: get_in(body, ["results", "documents", "hits"]) || []
  defp ids(body), do: Enum.map(hits(body), & &1["_id"])

  @drafts_url "/v1/search/#{@dataset}?q=#{@probe}&surfaces=documents&perspective=drafts"

  describe "decayed bearer on the federated route (bare :api — outside the parent fix)" do
    test "POSITIVE CONTROL: an admin token DOES read the seeded draft here", %{
      conn: conn,
      admin: admin
    } do
      body = conn |> bearer(admin) |> federated_body(@drafts_url)

      assert "drafts.fsd-draft" in ids(body),
             "seed is not leak-observable on the federated route — every negative " <>
               "assertion in this file would be vacuous. Got ids: #{inspect(ids(body))}"
    end

    # WAS: "a garbage bearer gets 200 with published-only rows (fails CLOSED)".
    # The strict gate now refuses this caller outright, which is strictly
    # stronger than the clamp this cell used to assert.
    test "a garbage bearer is REFUSED 401 — the strict gate subsumes the clamp", %{conn: conn} do
      resp = conn |> bearer(@garbage) |> get(@drafts_url)

      assert resp.status == 401,
             "a presented-but-unverifiable bearer must be refused on this route; got " <>
               "#{resp.status} with body #{resp.resp_body}"

      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "unauthorized"

      # The refusal must WITHHOLD the corpus, not merely relabel it. Both the
      # draft and the published row must be absent from the body.
      refute resp.resp_body =~ "fsd-draft"
      refute resp.resp_body =~ "fsd-pub"
    end

    # WAS: "DECAYED half: the envelope signals that the drafts request was
    # downgraded". There is no longer a downgrade to signal for this
    # population — the request never reaches the perspective logic. The
    # envelope-echo claim now lives in the DURABLE half below and in the
    # anonymous cell, neither of which any authentication change can reach.
    test "DECAYED half: there is no envelope to read, because there is no answer", %{conn: conn} do
      resp = conn |> bearer(@garbage) |> get(@drafts_url)

      assert resp.status == 401

      body = Jason.decode!(resp.resp_body)

      # Explicitly NOT a search envelope: no perspective key, no results. A 401
      # that still carried a perspective echo would mean the controller ran.
      refute Map.has_key?(body, "perspective"),
             "a refused request must not render a search envelope: #{resp.resp_body}"

      refute Map.has_key?(body, "results")
    end

    # MOVED ONTO THE DURABLE CREDENTIAL (task-f7230d4a500fffb6). This cell used
    # a garbage bearer, which is now refused 401 and never reaches a page at
    # all. The argument it makes — a row-level indicator cannot speak on a
    # zero-row page, so only an envelope echo can — is about the CLAMP, not
    # about authentication, so it belongs on the valid-but-insufficient
    # `public-read` token that is still clamped. Same claim, same assertions,
    # on a population that survives every bearer gate.
    test "QUALIFIER: a per-row _draft flag is the ONLY indicator, and it needs a non-empty page",
         %{conn: conn, pubread: pubread} do
      body = conn |> bearer(pubread) |> federated_body(@drafts_url)

      # This is what a caller CAN see today — recorded so the RED above is not
      # read as "no information of any kind reaches the caller".
      assert Enum.all?(hits(body), &(&1["_draft"] == false))

      # And this is why the row flag was never a substitute for an envelope
      # echo: the indicator lives on ROWS, so a zero-row answer carries no
      # row-level indicator at all. That reasoning is UNCHANGED by the fix —
      # what changed is that the ENVELOPE now answers where the rows cannot,
      # which is the entire justification for adding it.
      empty =
        conn
        |> bearer(pubread)
        |> federated_body(
          "/v1/search/#{@dataset}?q=zzznomatchzzz&surfaces=documents&perspective=drafts"
        )

      assert hits(empty) == [],
             "zero-row precondition broken; got #{inspect(ids(empty))}"

      # The row-level channel is silent here, by construction — nothing to read.
      assert Enum.flat_map(hits(empty), &Map.take(&1, ["_draft"])) == []

      # The envelope-level channel is NOT silent, and it is now the only reason
      # a caller can tell "drafts were never searched" from "no drafts matched".
      assert empty["perspective"] == "published",
             "a zero-row page must still state the perspective it searched; " <>
               "body keys: #{inspect(Enum.sort(Map.keys(empty)))}"
    end

    test "a VALID public-read token is clamped here too — and 200s where the flat route 403s",
         %{conn: conn, pubread: pubread} do
      resp = conn |> bearer(pubread) |> get(@drafts_url)

      # STATUS PINNED EXPLICITLY. `Plugs.PublicRead` would answer 403
      # "perspective not allowed" — but it is not mounted on bare `:api`, so
      # the federated route answers 200 over the published corpus instead.
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert ids(body) == ["fsd-pub"], "expected the published row; got #{inspect(ids(body))}"
      refute "drafts.fsd-draft" in ids(body)
    end

    test "DURABLE half: the envelope signals the clamp for a token that VERIFIES", %{
      conn: conn,
      pubread: pubread
    } do
      # THE DURABLE HALF OF THIS PIN. `Auth.verify_token/1` succeeds for this
      # caller, so no strict-on-presented bearer gate can reach it — not the
      # one on `:api_grant_read`, and not any future one. If the garbage-bearer
      # case above ever starts 401ing, THIS case still holds; it is the reason
      # only an envelope echo could close this, and no authentication change
      # ever could.
      body = conn |> bearer(pubread) |> federated_body(@drafts_url)

      assert Map.has_key?(body, "perspective"),
             "a VALID public-read token asked for ?perspective=drafts, was clamped to " <>
               "published, and the body carries no perspective key to say so. " <>
               "Body keys: #{inspect(Enum.sort(Map.keys(body)))}"

      assert body["perspective"] == "published"

      # Posture unmoved for this population too.
      assert ids(body) == ["fsd-pub"]
    end

    # THE MISSING CELL. Every assertion above is on the DOWNGRADED side, and a
    # hardcoded `perspective: "published"` literal would satisfy all of them —
    # a reviewer could not tell the echo is dynamic. This pins the LOSING side
    # of the same claim: when the requested perspective is HONOURED, the echo
    # must say `drafts`, and the rows must agree with what it says.
    test "the echo is DYNAMIC: an honoured drafts request echoes drafts, not published", %{
      conn: conn,
      admin: admin,
      pubread: pubread
    } do
      body = conn |> bearer(admin) |> federated_body(@drafts_url)

      assert body["perspective"] == "drafts",
             "the echo must report the perspective ACTUALLY used, not a constant. " <>
               "Got #{inspect(body["perspective"])}"

      # The echo and the corpus must not disagree: it said drafts, so the draft
      # row must be there. An echo that can say `drafts` while serving the
      # published corpus would be a worse lie than saying nothing at all.
      assert "drafts.fsd-draft" in ids(body)

      # Two DIFFERENT values from the same route, same query, same instant —
      # only the credential differs. That is what makes it an echo.
      #
      # The clamped side uses the `public-read` token rather than a garbage
      # bearer (task-f7230d4a500fffb6): a garbage bearer is now refused 401 and
      # produces no envelope to compare against. Both credentials here VERIFY,
      # so this contrast is now purely about PERMISSION — a sharper
      # demonstration that the echo tracks the perspective actually used.
      clamped = conn |> bearer(pubread) |> federated_body(@drafts_url)
      assert clamped["perspective"] == "published"
      refute clamped["perspective"] == body["perspective"]
    end

    test "CONTRAST: the same VALID public-read token is refused LOUDLY on the flat route", %{
      conn: conn,
      pubread: pubread
    } do
      resp =
        conn
        |> bearer(pubread)
        |> get("/v1/data/query/#{@dataset}/#{@type_name}?perspective=drafts")

      # `:api_grant_read` mounts `Plugs.PublicRead`, which denies a non-published
      # perspective outright. Same credential, same question, same instant — one
      # route refuses it in the open and the other answers 200 in silence. THAT
      # asymmetry is the finding.
      assert resp.status == 403
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] =~ "perspective"
    end

    # WAS "…refused 401 on the flat route, answered 200 here" (#14433). That
    # cell pinned the LAST STANDING HALF of the asymmetry — the federated route
    # still answering a decayed bearer 200 in silence. task-f7230d4a500fffb6
    # closed exactly that, so the cell is restated as the PARITY it became.
    #
    # This is the cell that would silently rot if left alone: its flat-route
    # half would keep passing while the claim in its name went false. Renamed
    # and re-asserted rather than deleted, because "the two read surfaces agree"
    # is a contract worth pinning — a future mount that reaches one route and
    # not the other reopens the tenant swap this file documents.
    test "PARITY: the SAME decayed bearer is refused 401 on BOTH read surfaces",
         %{conn: conn} do
      refused_flat =
        conn
        |> bearer(@garbage)
        |> get("/v1/data/query/#{@dataset}/#{@type_name}?perspective=drafts")

      assert refused_flat.status == 401,
             "the flat route must REFUSE a presented-but-unverifiable bearer " <>
               "(#14318 mounts `strict_on_presented: true` on `:api_grant_read`); " <>
               "got #{refused_flat.status}"

      flat_body = Jason.decode!(refused_flat.resp_body)
      assert flat_body["error"]["code"] == "unauthorized"

      # A refusal carries no corpus and no perspective — there is nothing here a
      # caller could mistake for an answer.
      refute Map.has_key?(flat_body, "result")

      # THE HALF THAT MOVED. The federated route rode bare `:api` and answered
      # this identical credential 200 over the DEFAULT workspace's published
      # corpus — a tenant swap by credential decay. It now pipes through
      # `[:api, :api_strict_bearer]` and refuses the same way.
      refused_fed = conn |> bearer(@garbage) |> get(@drafts_url)

      assert refused_fed.status == 401,
             "the federated route must refuse the same decayed bearer the flat " <>
               "route refuses (task-f7230d4a500fffb6); got #{refused_fed.status} " <>
               "with body #{refused_fed.resp_body}"

      fed_body = Jason.decode!(refused_fed.resp_body)
      assert fed_body["error"]["code"] == "unauthorized"
      refute Map.has_key?(fed_body, "results")

      # Same credential, same question, same instant, two routes, ONE answer.
      assert refused_flat.status == refused_fed.status
      assert flat_body["error"]["code"] == fed_body["error"]["code"]
    end

    test "the flat route's echo is REAL: an anonymous drafts request reads back published", %{
      conn: conn
    } do
      # The signal asymmetry in the @moduledoc rests on `QueryController`
      # echoing `result.perspective`, and the test above can no longer show it
      # (that caller is refused before the controller ever runs). So it is shown
      # with the population #14318 deliberately does NOT touch: a request that
      # presents NO `Authorization` header, which is a supported public read
      # tier and passes `OptionalToken` untouched on every mount, strict arm
      # included. `AnonPerspective.anon_pinned?/1` pins it to `:published`.
      resp = get(conn, "/v1/data/query/#{@dataset}/#{@type_name}?perspective=drafts")

      assert resp.status == 200,
             "an anonymous read is a supported surface on the flat route; got #{resp.status}"

      body = Jason.decode!(resp.resp_body)

      # It asked for drafts, it was clamped to published, and it SAYS SO. That
      # honesty is what the federated route lacked before the echo was added.
      assert body["result"]["perspective"] == "published",
             "expected the flat query route to echo its resolved perspective"

      # And the clamp itself holds: the seeded draft is not served.
      assert Enum.map(body["result"]["documents"], & &1["_id"]) == ["fsd-pub"]
    end
  end
end
