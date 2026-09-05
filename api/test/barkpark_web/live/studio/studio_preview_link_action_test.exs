defmodule BarkparkWeb.Studio.StudioPreviewLinkActionTest do
  @moduledoc """
  S9 criterion 4 — PREVIEW AFFORDANCE, SCOPED HONESTLY.

  A per-TYPE link-action pointing at the page's draft-mode URL on the
  consumer site. The template lives at the schema's `desk["preview"]`; the
  href is that template with the document's own slug interpolated.

  What this suite pins:

    * a type WITH a template renders the link-action, with the href derived
      from template + slug, opening in a new tab;
    * a type WITHOUT one renders NO link-action at all — not a dead link,
      not a `#` href;
    * a template naming `:slug` against a slugless document renders nothing,
      because a URL pointing at the wrong page is worse than no button;
    * the link carries no secret and mints no token. The signing half is
      BLOCKED ON S1 #7 (drafts-readable token tier, task-3a5a2a0662b0a661):
      every mintable token is public-tier today, so the Next.js draft-mode
      route (which verifies an HMAC over `path`+`expiry`) will answer 401
      until that tier lands. This suite asserts the affordance ONLY.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.DocActions

  @dataset "production"
  @admin_token "preview-link-admin"

  @template "https://site.example/api/draft?path=/blog/:slug"

  defp admin_conn(conn) do
    {:ok, _} =
      Barkpark.Auth.create_token(@admin_token, "preview link admin", @dataset, [
        "read",
        "write",
        "admin"
      ])

    Plug.Test.init_test_session(conn, %{"api_token" => @admin_token})
  end

  defp seed_type(name, desk) do
    {:ok, schema} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => String.capitalize(name),
          "icon" => "file-text",
          "visibility" => "public",
          "desk" => desk,
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "string"}
          ]
        },
        @dataset
      )

    schema
  end

  setup %{conn: conn} do
    previewable = seed_type("previewable", %{"preview" => @template})
    plain = seed_type("plain", %{})

    {:ok, _} =
      Content.create_document(
        "previewable",
        %{
          "doc_id" => "pv1",
          "title" => "Hello",
          "content" => %{"slug" => "hello-world"}
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "plain",
        %{"doc_id" => "pl1", "title" => "Plain", "content" => %{"slug" => "plain-one"}},
        @dataset
      )

    {:ok, conn: admin_conn(conn), previewable: previewable, plain: plain}
  end

  describe "a type WITH a preview template" do
    test "renders the Preview link-action at the doc's draft-mode URL", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/previewable/pv1"))

      rendered_link? = html =~ ~s(data-test-id="preview-draft")

      assert rendered_link?,
             "expected a Preview link-action (data-test-id=preview-draft) in the editor header"

      expected_href = "https://site.example/api/draft?path=/blog/hello-world"
      href_correct? = html =~ expected_href

      assert href_correct?,
             "expected the Preview href to be #{expected_href} — derived from the type's " <>
               "desk.preview template and the document's slug. The uninterpolated template " <>
               "or a missing href means the derivation did not run."

      # It leaves the Studio's origin: a same-tab navigation would tear the
      # LiveView (and any unsaved edit) down behind the editor's back.
      new_tab? = html =~ ~s(target="_blank")
      assert new_tab?, "expected the Preview link to open in a new tab"
    end

    test "the resolved action is a link kind carrying the raw template, no secret", %{
      previewable: schema
    } do
      doc = Content.get_document("previewable", "pv1", @dataset)

      action = DocActions.preview_doc_action(schema, doc)

      is_link? = is_map(action) and action["kind"] == "link"
      assert is_link?, "expected a link-kind doc action, got: #{inspect(action)}"

      href = get_in(action, ["opts", "href"])
      template_carried? = href == @template
      assert template_carried?, "expected the raw template on opts.href, got: #{inspect(href)}"

      # BLOCKED ON S1 #7: no signature, no expiry, no token is minted here.
      # The draft-mode route verifies an HMAC it cannot be given yet.
      carries_secret? =
        String.contains?(href, "sign=") or String.contains?(href, "secret=") or
          String.contains?(href, "token=")

      refute carries_secret?,
             "the preview link must carry no secret and mint no token — the drafts-readable " <>
               "tier is S1 #7 and has not landed"
    end
  end

  describe "a type WITHOUT a preview template" do
    test "renders no Preview link-action at all", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/plain/pl1"))

      no_link? = not (html =~ ~s(data-test-id="preview-draft"))

      assert no_link?,
             "a type with no desk.preview template must render NO Preview affordance — " <>
               "not a dead link, not a '#' href"
    end

    test "preview_doc_action/2 returns nil for a schema with no template", %{plain: schema} do
      doc = Content.get_document("plain", "pl1", @dataset)

      absent? = is_nil(DocActions.preview_doc_action(schema, doc))
      assert absent?, "expected nil for a type declaring no desk.preview"
    end
  end

  describe "an unfillable placeholder" do
    test "a :slug template against a slugless doc renders nothing", %{previewable: schema} do
      {:ok, _} =
        Content.create_document(
          "previewable",
          %{"doc_id" => "pv-noslug", "title" => "No slug", "content" => %{}},
          @dataset
        )

      doc = Content.get_document("previewable", "pv-noslug", @dataset)

      absent? = is_nil(DocActions.preview_doc_action(schema, doc))

      assert absent?,
             "a template naming :slug against a document with no slug would point at the " <>
               "wrong page — no button is better than a wrong one"
    end
  end
end
