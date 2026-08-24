defmodule BarkparkWeb.Integration.PublicReaderDraftsIdLeakTest do
  @moduledoc """
  The `drafts.`-id clamp on the PUBLIC READER surfaces — the anonymous,
  token-free twin of `BarkparkWeb.Integration.DraftsIdDocClampTest`.

  That suite seals the `/v1/data/doc` + `/v1/preview/doc` API routes, where the
  clamp is one `AnonPerspective.anon_pinned?/1` clause in `QueryController`.
  The public READERS never touch that clause: they resolve through
  `Content.Papers.get_public_document_with_workspace/3`, which called
  `Query.resolve_docs_by_ids/3` with `workspace_id:` ONLY. `published_only` is
  OPT-IN there (`Query.maybe_published_only/2` — absent ⇒ query untouched), so
  the draft row was addressable by its real id with no token at all:

      GET  /sheets/drafts.<slug>                    → 200, the unpublished grid
      GET  /papers/drafts.<slug>                    → 200, the unpublished blocks
      GET  /d/production/papers/drafts.<slug>       → 200, same
      GET  /papers/drafts.<slug>/email              → 200, same, as an email body
      GET  /d/production/papers/drafts.<slug>/email → 200, same
      POST …/papers/drafts.<slug>/form-responses    → 201, anchored to a
                                                      paper nobody published

  The bare slug was always safe: `Writer.create_document/4` force-prefixes every
  new row, so an unpublished doc has no bare row and its bare spelling 404s.
  Publishing writes the bare row; the NEXT draft edit recreates `drafts.<slug>`
  carrying in-progress content. Asking for it by that id returned it.

  ## Why one file for every door

  Eight anonymous routes sit on the `:public_root` / `:public_api` buckets and
  reach this one resolver (`Bulldocs.register_routes/1`,
  `Sheets.register_routes/1`).

  The W10 lesson `DraftsIdDocClampTest` cites: a clamp re-probed on one of its
  surfaces produces a FALSE SEAL. `/papers/:slug/source` already carried the
  guard (`fetch_published("drafts." <> _slug, …), do: nil`, plus
  `AnonPerspective.resolve/2`) and its sibling doors did not — the
  guard-exists-but-this-door-misses-it shape. Every door that reaches the
  public resolver is asserted here, including the one that was already correct,
  so a future regression on ANY of them reddens this file.

  ## Fail-closed, not fail-broken

  Every negative is paired with a positive control on the SAME route: the
  PUBLISHED spelling still serves the published bytes 200. Without that, a 404
  on the `drafts.` spelling would be vacuous — it could equally mean the route
  is gone. And `Query.resolve_docs_by_ids/3` WITHOUT `published_only` still
  returns the draft row, proving the fix clamps the public reader's perspective
  rather than making draft rows globally unreadable (the authorized Studio path
  is the same resolver).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @dataset "production"

  @published_body "PUBLISHED-BODY-VISIBLE"
  @draft_secret "DRAFT-ONLY-SECRET-XYZZY"

  setup do
    # The public surface resolves within the seeded Default workspace
    # (get_public_document fails closed without one).
    Barkpark.TenancyFixtures.ensure_default_scope!()
    :ok
  end

  # Publish `slug` with @published_body, then leave a draft row at
  # `drafts.<slug>` carrying @draft_secret — the exact post-publish state a
  # paper/sheet sits in while someone is editing it.
  defp published_with_dirty_draft!(type, slug, content_fun) do
    # A `paper` publish must clear the authoring wall (description + registered
    # weighted tags, both INSIDE `content`); `LabelFixtures` is the sanctioned
    # wall-compliant wrap. A `sheet` publish is not walled.
    with_description = fn marker ->
      case type do
        "paper" -> LabelFixtures.with_registered_labels(content_fun.(marker), @dataset)
        _ -> content_fun.(marker)
      end
    end

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => slug,
          "title" => "Public Title",
          "content" => with_description.(@published_body)
        },
        @dataset
      )

    {:ok, _} = Content.publish_document(slug, type, @dataset)

    {:ok, draft} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => slug,
          "title" => "Draft Title",
          "content" => with_description.(@draft_secret)
        },
        @dataset
      )

    # Guard the fixture itself: the draft row must really exist at the
    # `drafts.` id, or every 404 below is vacuous.
    assert draft.doc_id == "drafts." <> slug

    draft
  end

  defp paper_content(marker) do
    %{
      "blocks" => [
        %{
          "id" => "b1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => marker}]
        }
      ]
    }
  end

  defp sheet_content(marker) do
    %{"tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => marker}}}]}
  end

  # ── /sheets/:slug — SheetsReaderLive (Sheets plugin, :public_root) ─────────

  describe "GET /sheets/drafts.<slug> (SheetsReaderLive, anonymous)" do
    setup do
      published_with_dirty_draft!("sheet", "pdl-sheet", &sheet_content/1)
      :ok
    end

    test "the published spelling still serves published content (positive control)",
         %{conn: conn} do
      conn = get(conn, "/sheets/pdl-sheet")
      html = html_response(conn, 200)

      assert html =~ @published_body
      refute html =~ @draft_secret
    end

    test "the drafts.-prefixed spelling is a real 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/sheets/drafts.pdl-sheet") end
    end
  end

  # ── /papers/:slug — BulldocsLive flat + dataset readers ────────────────────

  describe "GET /papers/drafts.<slug> (BulldocsLive, anonymous)" do
    setup do
      published_with_dirty_draft!("paper", "pdl-paper", &paper_content/1)
      :ok
    end

    test "the published spelling still serves published content (positive control)",
         %{conn: conn} do
      conn = get(conn, "/papers/pdl-paper")
      html = html_response(conn, 200)

      assert html =~ @published_body
      refute html =~ @draft_secret
    end

    test "the flat reader 404s the drafts.-prefixed spelling", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/papers/drafts.pdl-paper") end
    end

    test "the dataset reader /d/:dataset/papers/:slug 404s it too", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/d/production/papers/drafts.pdl-paper") end
    end

    test "the dataset reader still serves the published spelling (positive control)",
         %{conn: conn} do
      conn = get(conn, "/d/production/papers/pdl-paper")
      html = html_response(conn, 200)

      assert html =~ @published_body
      refute html =~ @draft_secret
    end
  end

  # ── /papers/:slug/email — BulldocsEmailController ──────────────────────────
  #
  # Its moduledoc claims it "shares each route's visibility/capability
  # contract; a missing/unpublished slug is a plain 404". `fetch_paper(slug,
  # dataset, [])` went straight to `Content.get_public_paper/2` with neither
  # `AnonPerspective` nor a `drafts.` clause, so that claim was false.

  describe "GET /papers/drafts.<slug>/email (BulldocsEmailController, anonymous)" do
    setup do
      published_with_dirty_draft!("paper", "pdl-email", &paper_content/1)
      :ok
    end

    test "the published spelling still renders the email body (positive control)",
         %{conn: conn} do
      conn = get(conn, "/papers/pdl-email/email")
      body = response(conn, 200)

      assert body =~ @published_body
      refute body =~ @draft_secret
    end

    test "the drafts.-prefixed spelling is a plain 404", %{conn: conn} do
      conn = get(conn, "/papers/drafts.pdl-email/email")

      body = response(conn, 404)
      refute body =~ @draft_secret
    end

    test "the /d/:dataset/ variant of the same door 404s it too", %{conn: conn} do
      conn = get(conn, "/d/production/papers/drafts.pdl-email/email")

      body = response(conn, 404)
      refute body =~ @draft_secret
    end

    test "the /d/:dataset/ variant still serves the published spelling (positive control)",
         %{conn: conn} do
      conn = get(conn, "/d/production/papers/pdl-email/email")
      body = response(conn, 200)

      assert body =~ @published_body
      refute body =~ @draft_secret
    end
  end

  # ── /papers/:slug/source — BulldocsSourceController ────────────────────────
  #
  # This door was ALREADY correct — `AnonPerspective.resolve/2` pins an
  # anonymous caller to `:published`, and `fetch_published("drafts." <> _, …)`
  # returns nil. It is asserted anyway: it is the door whose guard the others
  # were missing, and an unguarded refactor of the shared resolver must not
  # silently regress it.

  describe "GET /papers/drafts.<slug>/source (BulldocsSourceController, anonymous)" do
    setup do
      published_with_dirty_draft!("paper", "pdl-source", &paper_content/1)
      :ok
    end

    test "the published spelling still serves the source (positive control)", %{conn: conn} do
      conn = get(conn, "/papers/pdl-source/source")
      body = response(conn, 200)

      assert body =~ @published_body
      refute body =~ @draft_secret
    end

    test "the drafts.-prefixed spelling is a 404", %{conn: conn} do
      conn = get(conn, "/papers/drafts.pdl-source/source")
      assert response(conn, 404)
    end

    test "?perspective=drafts cannot reopen it for an anonymous caller", %{conn: conn} do
      conn = get(conn, "/papers/pdl-source/source?perspective=drafts")
      body = response(conn, 200)

      refute body =~ @draft_secret
      assert body =~ @published_body
    end

    test "?perspective=raw cannot reopen it for an anonymous caller", %{conn: conn} do
      conn = get(conn, "/papers/drafts.pdl-source/source?perspective=raw")
      assert response(conn, 404)
    end

    test "the /d/:dataset/ variant of the same door is a 404 too", %{conn: conn} do
      conn = get(conn, "/d/production/papers/drafts.pdl-source/source")
      assert response(conn, 404)
    end
  end

  # ── POST /v1/plugins/bulldocs/papers/:slug/form-responses ─────────────────
  #
  # Not a read leak — an anonymous WRITE anchored to a paper nobody published.
  # The controller's own trust model says "the slug must resolve through
  # `get_public_paper/1` (Default-workspace pinned, fail-closed)", and that
  # resolver accepted the `drafts.` id, so the paper-anchored guarantee held
  # only for the published spelling. Same resolver, same fix.

  describe "POST .../papers/drafts.<slug>/form-responses (anonymous)" do
    setup do
      form = fn marker ->
        %{
          "blocks" => [
            %{
              "id" => "f1",
              "type" => "form",
              "questions" => [%{"id" => "q1", "label" => marker}]
            }
          ]
        }
      end

      published_with_dirty_draft!("paper", "pdl-form", form)
      :ok
    end

    test "the published spelling still accepts a submission (positive control)", %{conn: conn} do
      conn =
        post(conn, "/v1/plugins/bulldocs/papers/pdl-form/form-responses", %{
          "answers" => %{"q1" => "hello"}
        })

      assert %{"ok" => true} = json_response(conn, 201)
    end

    test "the drafts.-prefixed spelling cannot be anchored to", %{conn: conn} do
      conn =
        post(conn, "/v1/plugins/bulldocs/papers/drafts.pdl-form/form-responses", %{
          "answers" => %{"q1" => "hello"}
        })

      assert json_response(conn, 404)
    end
  end

  # ── the authorized path must keep working ─────────────────────────────────

  describe "positive control: the draft row stays readable to an authorized reader" do
    setup do
      draft = published_with_dirty_draft!("paper", "pdl-authz", &paper_content/1)
      %{draft: draft}
    end

    test "the Studio resolver (no published_only) still returns the draft row", %{draft: draft} do
      {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

      [found] = Content.resolve_docs_by_ids([draft.doc_id], @dataset, workspace_id: ws.id)

      assert found.doc_id == "drafts.pdl-authz"
      assert inspect(found.content) =~ @draft_secret
    end

    test "the same resolver WITH published_only refuses it", %{draft: draft} do
      {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

      assert Content.resolve_docs_by_ids([draft.doc_id], @dataset,
               workspace_id: ws.id,
               published_only: true
             ) == []
    end
  end
end
