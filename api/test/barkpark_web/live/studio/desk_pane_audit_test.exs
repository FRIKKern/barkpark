defmodule BarkparkWeb.Studio.DeskPaneAuditTest do
  @moduledoc """
  The 24-hour audit of the desk's edit pane top (LOOKS PR 1 and 2), three
  findings:

    * the status pills say their state in words, not only in colour
      (task-130c7744986719ec);
    * the Classic editor's block-identity alert is shown under the header,
      not hidden with the old toolbar row (task-012fea3af50e3881);
    * a required field's input says so (`aria-required`), its "*" is not
      read out as "star", and its label says "required" in words, so a
      control with no `aria-required` is not silent (task-c638865f3fdf5019).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @chips "#{@pane} > .pane-header > .dk-chips[data-desk-status]"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "audit_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Audit #{n}",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "title",
              "title" => "Title",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{
              "name" => "subtitle",
              "title" => "Subtitle",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{"name" => "note", "title" => "Note", "type" => "string"},
            %{
              "name" => "agree",
              "title" => "Agree",
              "type" => "boolean",
              "validation" => %{"required" => true}
            },
            %{
              "name" => "cover",
              "title" => "Cover",
              "type" => "image",
              "validation" => %{"required" => true}
            },
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-audit-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-audit",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, n: n, type: type, scope: scope}
  end

  defp doc!(c, attrs \\ %{}) do
    id = "audit-#{c.n}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        Map.merge(%{"doc_id" => id, "title" => "Here"}, attrs),
        @dataset
      )

    id
  end

  defp open(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # What a screen reader reads from a piece of markup: its text, less
  # anything aria-hidden.
  defp spoken(html) do
    html
    |> String.replace(~r/<(\w+)[^>]*aria-hidden="true"[^>]*>.*?<\/\1>/s, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp pills(view), do: view |> element(@chips) |> render() |> spoken()

  # ── the pills ─────────────────────────────────────────────────────────────

  test "never published: read as not published, its draft as unpublished changes", c do
    view = open(c, doc!(c))
    assert pills(view) == "Not published Draft: unpublished changes"
  end

  test "a published document with edits is read as published, its draft as changed", c do
    id = doc!(c)
    {:ok, _} = Content.publish_document(id, c.type, @dataset)
    view = open(c, id)
    assert pills(view) == "Published Draft: no changes"

    view |> element("#editor-form") |> render_change(%{"doc" => %{"note" => "Typed"}})
    render_async(view, 5_000)

    assert eventually(fn -> pills(view) == "Published Draft: unpublished changes" end),
           pills(view)
  end

  test "the pills look as before: the words Published and Draft, aria-hidden", c do
    html = open(c, doc!(c)) |> element(@chips) |> render()
    assert html =~ ~r/<span class="dk-chip-label" aria-hidden="true">\s*Published\s*<\/span>/
    assert html =~ ~r/<span class="dk-chip-label" aria-hidden="true">\s*Draft\s*<\/span>/
  end

  # ── the block-identity alert ──────────────────────────────────────────────

  test "a document with duplicate block ids shows the Studio's alert under the header", c do
    para = fn text ->
      %{"id" => "dup", "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
    end

    view = open(c, doc!(c, %{"content" => %{"blocks" => [para.("A"), para.("B")]}}))

    alert = ~s(#{@pane} > [id$="-notes"] [role="alert"][data-desk-identity-error])
    assert has_element?(view, alert)

    assert render(element(view, alert)) =~
             "Block editing is unavailable because this document has duplicate block IDs."
  end

  test "a document whose blocks are fine shows no such alert", c do
    view = open(c, doc!(c))
    refute has_element?(view, "#{@pane} [data-desk-identity-error]")
  end

  # ── required fields ───────────────────────────────────────────────────────

  test "a required field's input says aria-required and its * is not read out", c do
    view = open(c, doc!(c))

    for f <- ~w(title subtitle) do
      assert has_element?(
               view,
               ~s(#{@pane} #editor-form input[name="doc[#{f}]"][aria-required="true"])
             )
    end

    refute has_element?(view, ~s(#{@pane} #editor-form input[name="doc[note]"][aria-required]))
    assert has_element?(view, ~s(#{@pane} #editor-form .field-required[aria-hidden="true"]))
    refute has_element?(view, ~s|#{@pane} #editor-form .field-required:not([aria-hidden="true"])|)
  end

  # A required boolean or image has no `aria-required` of its own, so with
  # the "*" hidden the label must say "required" in words, or the field is
  # silent (review of #26109).
  test "every required field's label says required in words; an optional one does not", c do
    view = open(c, doc!(c))
    html = view |> element("#{@pane} #editor-form") |> render()

    for label <- ~w(Title Subtitle Agree Cover) do
      assert html =~
               ~r/<(label|legend)[^>]*class="editor-field-label"[^>]*>\s*#{label}\s*<span class="field-required" aria-hidden="true">\*<\/span><span class="sr-only">required<\/span>/,
             "#{label} says required"
    end

    refute html =~ ~r/>\s*Note\s*<span class="field-required"/
    refute html =~ ~r/>\s*Note\s*<span class="sr-only">/
  end

  # Control: the old Studio keeps its visible "*" as it was, and its
  # required inputs say so too.
  test "the old Studio keeps its * and marks the input required", c do
    id = doc!(c)
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{c.type}/#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)

    assert has_element?(view, ~s|#editor-form .field-required:not([aria-hidden])|)
    assert has_element?(view, ~s(#editor-form input[name="doc[subtitle]"][aria-required="true"]))
    refute has_element?(view, "#editor-form .editor-field-label .sr-only")
  end
end
