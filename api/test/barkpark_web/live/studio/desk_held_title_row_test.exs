defmodule BarkparkWeb.Studio.DeskHeldTitleRowTest do
  @moduledoc """
  task-82becc4945d1ad1e: while A holds a title the store refused, A's
  header, tab and big title name A's text (`PageTitle`, #28322), but the
  desk's list row named the stored title, B's after B's rename. TanStack's
  row reads the doc its cache overlays with this editor's unsent values, so
  it names A's text too. The row takes the header's rule (`PageTitle.held/1`):
  only the open document's row, only in A's tab.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @header "[data-pane-editing] > .pane-header > .pane-header-title"
  # Over 255 characters: the store refuses it, and the form holds it.
  @long "Doc 7 " <> String.duplicate("x", 300)

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "held_row_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Held rows",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "held-row-#{n}"
    other = "held-row-other-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Doc 7", "content" => %{"notes" => "n0"}},
        @dataset
      )

    {:ok, _} = Content.create_document(type, %{"doc_id" => other, "title" => "Other"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "held-row-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "held-row", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     type: type,
     id: id,
     other: other}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    assert eventually(fn -> rows(view)[c.id] != nil and rows(view)[c.other] != nil end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp text(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  # The list's document rows: the id each opens => its title.
  defp rows(view) do
    render_async(view, 1_000)
    html = view |> element(~s([data-pane-index="1"])) |> render()

    for [_, href, title] <-
          Regex.scan(
            ~r/<a href="([^"]+)"[^>]*data-desk-row.*?<span class="dk-row-title">(.*?)<\/span>/s,
            html
          ),
        into: %{} do
      id = href |> URI.decode() |> String.split(";") |> List.last() |> String.split(",") |> hd()
      {id, text(title)}
    end
  end

  defp header(view), do: view |> element(@header) |> render() |> text()

  defp posts(view, key, value) do
    form = Map.take(assigns(view).editor_form, ~w(title notes))

    view
    |> element("[data-pane-editing] #editor-form")
    |> render_change(%{"_target" => ["doc", key], "doc" => Map.put(form, key, value)})
  end

  defp held!(a) do
    posts(a, "title", @long)

    assert eventually(fn ->
             MapSet.member?(assigns(a).editor_unsaved_keys || MapSet.new(), "title")
           end)
  end

  test "A holds a refused title, B renames: A's row shows A's text", c do
    a = open(c)
    b = open(c)
    held!(a)
    assert eventually(fn -> rows(a)[c.id] == @long end)

    posts(b, "title", "Doc 7 B1")
    assert eventually(fn -> rows(b)[c.id] == "Doc 7 B1" end)

    render(a)
    assert eventually(fn -> rows(a)[c.id] == @long end)
    assert rows(a)[c.id] == header(a)
    assert rows(a)[c.other] == "Other"
    # B holds nothing: its row is the stored title.
    assert rows(b)[c.id] == "Doc 7 B1"
  end

  test "once A's title lands, the row is the stored title again", c do
    a = open(c)
    held!(a)
    assert eventually(fn -> rows(a)[c.id] == @long end)

    posts(a, "title", "Doc 7 A1")

    assert eventually(fn -> rows(a)[c.id] == "Doc 7 A1" end)
    assert header(a) == "Doc 7 A1"
  end

  # #28334 review: a document is one id of one type. A reference chain puts
  # a list of type X beside the editor of a type-Y document with the same
  # id; X's row is another document and keeps its stored title.
  test "a row of another type with the same id keeps its stored title", c do
    twin = c.type <> "_y"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => twin,
          "title" => "Held twins",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} = Content.create_document(twin, %{"doc_id" => c.id, "title" => "Y twin"}, @dataset)

    path = c.path <> ";" <> c.id <> ",type=" <> twin
    {:ok, a, _html} = live(c.conn, path)
    render_async(a, 5_000)
    assert eventually(fn -> assigns(a).editor_type == twin end)
    assert eventually(fn -> rows(a)[c.id] == "Doc 7" end)

    view = a
    form = Map.take(assigns(view).editor_form, ~w(title))

    view
    |> element("[data-pane-editing] #editor-form")
    |> render_change(%{"_target" => ["doc", "title"], "doc" => Map.put(form, "title", @long)})

    assert eventually(fn -> header(a) == @long end)
    assert rows(a)[c.id] == "Doc 7"
  end

  # task-dfd5b9df60547682: each keystroke of a held title changes the open
  # row's title, so the list pane renders again. Its rows read the held title
  # through the pane's assigns, so every row was sent again: about twice
  # main's bytes per keystroke on a 100-row list. Only the open row may be.
  test "a keystroke in a held title sends the open row alone, not the others", c do
    a = open(c)
    held!(a)
    assert eventually(fn -> rows(a)[c.id] == @long end)

    form = assigns(a).editor_form |> Map.take(~w(title notes)) |> Map.put("title", @long <> "z")
    post = %{"_target" => ["doc", "title"], "doc" => form}

    sent =
      sent_by(a, fn -> a |> element("[data-pane-editing] #editor-form") |> render_change(post) end)

    assert sent =~ "xz"
    refute sent =~ "Other", "the other row was sent again"
    assert rows(a)[c.id] == @long <> "z"
    assert rows(a)[c.other] == "Other"
  end

  # Everything the LiveView process sends to the page while `fun` runs (its
  # diffs), as one string.
  defp sent_by(view, fun) do
    :erlang.trace(view.pid, true, [:send])
    fun.()
    :erlang.trace(view.pid, false, [:send])

    Stream.repeatedly(fn ->
      receive do
        {:trace, _pid, :send, msg, _to} ->
          inspect(msg, limit: :infinity, printable_limit: :infinity)
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  # Control (passes on main): nothing held, the row is the stored title.
  test "with nothing held the row follows B's rename", c do
    a = open(c)
    b = open(c)
    posts(b, "title", "Doc 7 B1")
    assert eventually(fn -> rows(a)[c.id] == "Doc 7 B1" end)
    assert header(a) == "Doc 7 B1"
  end
end
