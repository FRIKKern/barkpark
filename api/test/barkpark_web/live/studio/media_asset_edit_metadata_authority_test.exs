defmodule BarkparkWeb.Studio.MediaAssetEditMetadataAuthorityTest do
  @moduledoc """
  task-3cae133ab3aca51d — ONE AUTHORITY FOR ONE WRITE.

  `altText` on a `mediaAsset` is writable through TWO seams:

    * the v1 media HTTP seam — `V1.MediaController.patch_metadata` guards on
      `Barkpark.Media.Storage.Access.allowed?/4` with `:edit_metadata`
      (`media_controller.ex:561`);
    * the Studio DOCUMENT seam, opened by PR #16066 — `form#editor-form` ->
      `Fields.save/2` -> `Shared.do_autosave/2` -> `Content.upsert_draft/6`,
      guarded by the Studio editor write gate (`Caps` `:write` + tenancy).

  THE DIVERGENCE THE ROW ASKS ABOUT. `Access`'s permission set withholds
  `edit_metadata` from an authenticated NON-ADMIN when the asset document is
  CHECKED OUT by a different actor (`permission_set/2`'s final `--` arm). The
  Studio write gate has no notion of a media checkout lock — nothing in `Caps`
  or the tenancy check reads `checkedOutBy` — so the SAME principal that the
  HTTP seam answers 403 for was accepted by the document seam.

  MEASURED on the pre-fix tree (this file's own RED-before run):

      1) test the media-REFUSED principal cannot set altText through the
         Studio editor either
         ** (ExUnit.AssertionError) the Studio document seam WROTE altText for a
         principal the media permission set REFUSES edit_metadata
         (checkedOutBy: "another-editor", token perms ["read","write"]);
         content read back: %{"altText" => %{"nob" => "SKREVET AV EN NEKTET SKRIBENT"}}

  ...which is a permission WIDENING through the UI: the lock the HTTP seam
  enforces was bypassable by opening the same asset in the Studio.

  THE FIX IS ONE AUTHORITY, NOT A SECOND COPY. `Access.edit_metadata_allowed?/2`
  is the pure `(principal, doc)` core that `allowed?/4`'s `:edit_metadata` arm
  already was — `permission_set/2` reads nothing but `.assigns`, which a
  `Phoenix.LiveView.Socket` carries in the same shape as a `Plug.Conn` (the
  contract `authenticated?/1` already publishes). `allowed?/4` now delegates to
  it, so the HTTP behaviour is byte-identical, and `Shared.do_autosave/2`
  consults the SAME function for a `mediaAsset` target. No new permission kind.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Media.Storage.Access
  alias Barkpark.Media.Storage.MediaFile

  @dataset "production"

  defp seed_media_asset_schema! do
    attrs =
      Path.join([:code.priv_dir(:barkpark), "plugins", "media", "schemas", "media_asset.json"])
      |> File.read!()
      |> Jason.decode!()

    {:ok, _} = Content.upsert_schema(attrs, @dataset)
    :ok
  end

  # The asset the write targets. `checked_out_by` is what makes the media
  # permission set refuse `edit_metadata` to a non-admin actor.
  defp seed_asset_doc!(slug, checked_out_by) do
    content = if checked_out_by, do: %{"checkedOutBy" => checked_out_by}, else: %{}

    {:ok, doc} =
      Content.upsert_document(
        "mediaAsset",
        %{
          "doc_id" => slug,
          "title" => "Cover photo",
          "status" => "published",
          "content" => content
        },
        @dataset,
        source: :api
      )

    doc
  end

  # A NON-ADMIN editor: read+write, which is everything the Studio write gate
  # asks for. `label` is what `Access.actor_label/1` compares the checkout
  # against, so it is the identity that does — or does not — hold the lock.
  defp editor_conn!(label) do
    raw = "s9-auth-#{System.unique_integer([:positive])}"

    {:ok, _} = Barkpark.Auth.create_token(raw, label, @dataset, ["read", "write"])

    # ConnCase.scoped_conn/0, not a bare build_conn/0: this conn reaches a route
    # the RateLimit plug meters before any credential plug, and the suite-wide
    # tripwire (rate_limit_test_conn_scope_test.exs) refuses an unscoped conn
    # that would share the one ip:127.0.0.1 bucket with every other test.
    {scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => raw}), label}
  end

  # The HTTP seam's own question, asked with the same principal shape the
  # controller hands it.
  defp http_allows_edit_metadata?(label, doc) do
    conn = %Plug.Conn{
      request_path: "/v1/media/assets/x",
      query_params: %{},
      assigns: %{
        api_token: %ApiToken{
          id: Ecto.UUID.generate(),
          label: label,
          permissions: ["read", "write"]
        }
      }
    }

    Access.allowed?(conn, %MediaFile{id: Ecto.UUID.generate()}, doc, :edit_metadata)
  end

  # THE WIRE SHAPE, not a hand-built one — `LocalizedTextField` emits
  # `name="doc[altText].nob"` and `Plug.Conn.Query` does not nest the trailing
  # dot segment (PR #16066's second defect).
  defp alt_text_wire(value) do
    Plug.Conn.Query.decode("doc[altText].nob=#{URI.encode_www_form(value)}")
  end

  defp read_back(slug) do
    doc =
      case Content.get_document("drafts.#{slug}", "mediaAsset", @dataset) do
        {:ok, d} ->
          d

        _ ->
          case Content.get_document(slug, "mediaAsset", @dataset) do
            {:ok, d} -> d
            _ -> nil
          end
      end

    doc && doc.content
  end

  setup do
    seed_media_asset_schema!()
    :ok
  end

  # ── FACT 1: the principal the media set REFUSES ────────────────────────────
  test "the media-refused principal cannot set altText through the Studio editor either" do
    slug = "s9-auth-locked-#{System.unique_integer([:positive])}"
    doc = seed_asset_doc!(slug, "another-editor")

    refuted? = not http_allows_edit_metadata?("s9-not-the-holder", doc)

    assert refuted?,
           "premise broken: the media permission set ALLOWS edit_metadata for this " <>
             "principal, so it is not the refused principal this test needs"

    {conn, _label} = editor_conn!("s9-not-the-holder")

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    refute html =~ "studio-unresolved-document-notice",
           "the editor did not open the asset; this test would be vacuous"

    render_click(view, "select-group", %{"group" => "metadata"})
    render_submit(view, "save", alt_text_wire("SKREVET AV EN NEKTET SKRIBENT"))

    content = read_back(slug)
    wrote? = is_map(content) and is_map(content["altText"])

    refute wrote?,
           "the Studio document seam WROTE altText for a principal the media permission " <>
             "set REFUSES edit_metadata (checkedOutBy: \"another-editor\", token perms " <>
             "[\"read\",\"write\"]); content read back: #{inspect(content)}"
  end

  # ── FACT 2, THE MIRROR: the principal the media set ALLOWS ─────────────────
  test "the principal the media set ALLOWS still writes altText through the Studio editor" do
    slug = "s9-auth-open-#{System.unique_integer([:positive])}"
    doc = seed_asset_doc!(slug, nil)

    allowed? = http_allows_edit_metadata?("s9-open-editor", doc)

    assert allowed?,
           "premise broken: the media permission set REFUSES edit_metadata for an " <>
             "unlocked asset, so this mirror proves nothing"

    {conn, _label} = editor_conn!("s9-open-editor")

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    render_click(view, "select-group", %{"group" => "metadata"})
    render_submit(view, "save", alt_text_wire("Et fyrtårn i tåke"))

    content = read_back(slug)
    stored? = is_map(content) and get_in(content, ["altText", "nob"]) == "Et fyrtårn i tåke"

    assert stored?,
           "the unify gate over-refused: a principal the media set ALLOWS could not " <>
             "set altText through the Studio editor; content was #{inspect(content)}"
  end

  # ── The lock HOLDER is not collateral: the same lock, held by this actor. ──
  test "the actor holding the checkout still writes altText through the Studio editor" do
    slug = "s9-auth-holder-#{System.unique_integer([:positive])}"
    doc = seed_asset_doc!(slug, "s9-lock-holder")

    allowed? = http_allows_edit_metadata?("s9-lock-holder", doc)

    assert allowed?,
           "premise broken: the media set refuses the checkout HOLDER, which is not " <>
             "what permission_set/2 says"

    {conn, _label} = editor_conn!("s9-lock-holder")

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    render_click(view, "select-group", %{"group" => "metadata"})
    render_submit(view, "save", alt_text_wire("Holderen skriver"))

    content = read_back(slug)
    stored? = is_map(content) and get_in(content, ["altText", "nob"]) == "Holderen skriver"

    assert stored?,
           "the checkout HOLDER was refused by the Studio seam; content was #{inspect(content)}"
  end

  # ── A NON-media document is untouched by the media authority. ──────────────
  test "a non-mediaAsset document is not gated by the media permission set" do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "s9AuthNote",
          "title" => "S9 Auth Note",
          "fields" => [%{"name" => "title", "type" => "string", "title" => "Title"}]
        },
        @dataset
      )

    slug = "s9-auth-note-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_document(
        "s9AuthNote",
        %{
          "doc_id" => slug,
          "title" => "Note",
          "status" => "published",
          # The SAME lock value that refuses a mediaAsset write. On a non-media
          # type it must mean nothing at all.
          "content" => %{"checkedOutBy" => "another-editor"}
        },
        @dataset,
        source: :api
      )

    {conn, _label} = editor_conn!("s9-not-the-holder")

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/s9AuthNote/#{slug}"))

    refute html =~ "studio-unresolved-document-notice",
           "the editor did not open the note; this test would be vacuous"

    render_submit(view, "save", %{"doc" => %{"title" => "RENAMED BY A NON-HOLDER"}})

    doc =
      case Content.get_document("drafts.#{slug}", "s9AuthNote", @dataset) do
        {:ok, d} -> d
        _ -> nil
      end

    renamed? = doc && doc.title == "RENAMED BY A NON-HOLDER"

    assert renamed?,
           "the media checkout lock leaked onto a non-media type; doc was #{inspect(doc && doc.title)}"
  end
end
