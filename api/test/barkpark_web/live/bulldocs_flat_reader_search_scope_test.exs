defmodule BarkparkWeb.BulldocsFlatReaderSearchScopeTest do
  @moduledoc """
  Owner ruling #30 Q10 (2026-10-03, task-1631e0fa917452d9): the flat
  `/papers/:slug` reader's `[[wikilink]]` and `#tag` typeahead search the
  paper's own workspace and project.

  The flat reader carries no `:current_workspace`, so the search named no
  workspace and leaned on dataset scoping alone. A legacy paper of ANOTHER
  workspace whose `dataset_id` is NULL (pre-backfill) matched by its dataset
  string and surfaced as a candidate.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo}

  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {default_ws, default_proj} = ensure_default_scope!()
    suffix = System.unique_integer([:positive])
    foreign_ws = create_workspace!("flat-search-foreign-#{suffix}")
    foreign_proj = create_project!(foreign_ws)

    editor_slug = "flat-search-editor-#{suffix}"
    own_slug = "flat-search-own-#{suffix}"
    own_title = "Flat Search Candidate Own #{suffix}"
    own_tag = "flat-search-tag-own-#{suffix}"
    foreign_slug = "flat-search-foreign-#{suffix}"
    foreign_title = "Flat Search Candidate Foreign #{suffix}"
    foreign_tag = "flat-search-tag-foreign-#{suffix}"

    seed_paper!(default_ws, default_proj, editor_slug, "Flat search editor #{suffix}", nil)
    seed_paper!(default_ws, default_proj, own_slug, own_title, own_tag)
    seed_paper!(foreign_ws, foreign_proj, foreign_slug, foreign_title, foreign_tag)

    # The legacy shape the finding names: the foreign paper's rows predate the
    # dataset_id backfill.
    {n, _} =
      Repo.update_all(
        from(d in "documents", where: d.workspace_id == type(^foreign_ws.id, :binary_id)),
        set: [dataset_id: nil]
      )

    assert n > 0, "fixture did not produce a NULL-dataset_id foreign paper"

    raw = "flat-search-writer-#{suffix}"

    {:ok, _} =
      Auth.create_token(raw, "flat search writer", @dataset, ["read", "write"], default_ws.id)

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      editor_slug: editor_slug,
      own_slug: own_slug,
      own_tag: own_tag,
      foreign_slug: foreign_slug,
      foreign_title: foreign_title,
      foreign_tag: foreign_tag,
      suffix: suffix
    }
  end

  test "the flat reader's wikilink and tag search stay inside the paper's workspace", ctx do
    {:ok, view, _html} = live(ctx.conn, "/papers/#{ctx.editor_slug}")
    render_click(view, "paper-toggle-edit", %{})

    render_hook(view, "paper-wikilink-search", %{"query" => "Flat Search Candidate"})
    assert_reply(view, %{results: wikilinks})

    assert Enum.any?(wikilinks, &(&1.id == ctx.own_slug)),
           "the paper's own workspace candidate is missing — the search is dead, not scoped"

    refute Enum.any?(wikilinks, &(&1.id == ctx.foreign_slug or &1.title == ctx.foreign_title)),
           "another workspace's paper surfaced in the flat reader's wikilink search"

    render_hook(view, "paper-tag-search", %{"query" => "flat-search-tag"})
    assert_reply(view, %{results: tags})

    assert ctx.own_tag in tags
    refute ctx.foreign_tag in tags
  end

  defp seed_paper!(ws, project, slug, title, tag) do
    labels =
      case tag do
        nil -> %{}
        name -> Barkpark.LabelFixtures.with_named_labels(%{}, @dataset, [name])
      end

    attrs =
      Map.merge(
        %{
          "slug" => slug,
          "title" => title,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => [
            %{"id" => "heading", "type" => "heading", "level" => 1, "text" => title},
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body"}]
            }
          ]
        },
        labels
      )

    assert {:ok, _paper} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(attrs))
  end
end
