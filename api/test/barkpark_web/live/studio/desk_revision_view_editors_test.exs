defmodule BarkparkWeb.Studio.DeskRevisionViewEditorsTest do
  @moduledoc """
  The desk's read-only revision view (`RevisionView`) stands in for the
  form only. A sheet's grid and a paper's canvas are their own editors, so a
  `rev=` on one is not shown: the pane says so over the live editor, and no
  revision form or Revert is drawn over content the person never saw. And
  the form sits in the same holder live and in a revision, so picking a
  History row moves nothing around it (the row keeps the focus).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  setup %{conn: conn} do
    raw = "rev-editors-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "rev-editors", @dataset, ~w(read write admin), ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp open(c, path) do
    {:ok, view, _} = live(c.conn, "#{c.base}/#{path}")
    render_async(view, 5_000)
    view
  end

  defp not_shown!(view, rev) do
    refute has_element?(view, "[data-pane-editing] [data-desk-revision-form]")
    refute has_element?(view, "[data-pane-editing] [data-desk-revision-footer]")
    refute has_element?(view, "[data-pane-editing] [data-desk-revert-confirm]")
    assert has_element?(view, "[data-pane-editing] [data-desk-left-out]", rev)
  end

  describe "a sheet" do
    setup do
      stop = fn ->
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
            is_pid(pid) do
          try do
            GenServer.stop(pid, :normal, 5_000)
          catch
            :exit, _ -> :ok
          end
        end
      end

      stop.()

      Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session,
        debounce_ms: 60_000,
        idle_stop_ms: 60_000
      )

      on_exit(fn ->
        stop.()
        Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
      end)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "sheet",
            "title" => "Sheets",
            "visibility" => "private",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )

      :ok
    end

    test "its revision is not shown over the live grid: the pane says so", c do
      id = "rvsheet-#{System.unique_integer([:positive])}"
      tab = fn v -> %{"tabs" => [%{"name" => "Sheet 1", "cells" => %{"A1" => %{"v" => v}}}]} end

      {:ok, _} =
        Content.create_document(
          "sheet",
          %{"doc_id" => id, "title" => "Sheet R", "content" => tab.("OLD")},
          @dataset
        )

      {:ok, _} =
        Content.upsert_document(
          "sheet",
          %{"doc_id" => Content.draft_id(id), "title" => "Sheet R", "content" => tab.("LIVE")},
          @dataset
        )

      old =
        id
        |> Content.list_revisions("sheet", @dataset, limit: 10)
        |> Enum.find(
          &(get_in(&1.content || %{}, ["tabs", Access.at(0), "cells", "A1", "v"]) == "OLD")
        )

      view = open(c, "sheet;#{id}" <> @history <> ",rev=#{old.id}")
      not_shown!(view, old.id)
    end
  end

  test "a paper's revision is not shown over the live canvas: the pane says so", c do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    slug = "rvpaper-#{n}"

    para = fn text ->
      [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      ]
    end

    for text <- ["OLDPARA", "LIVEPARA"] do
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            title: "Paper #{n}",
            blocks: para.(text)
          })
        )
    end

    old =
      slug
      |> Content.list_revisions("paper", @dataset, limit: 10)
      |> Enum.find(&(inspect(&1.content) =~ "OLDPARA"))

    view = open(c, "paper;#{slug}" <> @history <> ",rev=#{old.id}")
    not_shown!(view, old.id)
  end

  test "the form sits in one holder live and in a revision, so a picked row keeps its place", c do
    n = System.unique_integer([:positive])
    type = "rvh_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Holder #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "rvh-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "v1"}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => Content.draft_id(id), "title" => "v2"},
        @dataset
      )

    rev =
      id
      |> Content.list_revisions(type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    holder = ~s([data-pane-editing] fieldset[id$="-form-holder"])
    # The form holder, then the inspectors' holders, in the same order either way.
    order = fn view ->
      Regex.scan(
        ~r/<(?:fieldset|aside)[^>]*\sid="([^"]*-(?:form-holder|inspector|history))"/,
        render(view)
      )
      |> Enum.map(&List.last/1)
    end

    view = open(c, "#{type};#{id}" <> @history)
    assert has_element?(view, holder <> ":not([disabled]) #editor-form")
    live_order = order.(view)

    render_patch(view, "#{c.base}/#{type};#{id}" <> @history <> ",rev=#{rev.id}")
    render_async(view, 5_000)

    assert has_element?(
             view,
             holder <>
               "[data-desk-revision-form] fieldset[data-desk-readonly-fields][disabled] #editor-form"
           )

    assert order.(view) == live_order
  end
end
