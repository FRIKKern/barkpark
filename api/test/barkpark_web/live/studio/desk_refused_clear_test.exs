defmodule BarkparkWeb.Studio.DeskRefusedClearTest.Halt do
  @moduledoc false
  # Refuses every write while the flag is on ("Save cancelled").
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(_doc),
    do: if(:persistent_term.get(__MODULE__, false), do: {:halt, "held"}, else: :ok)
end

defmodule BarkparkWeb.Studio.DeskRefusedClearTest do
  @moduledoc """
  A desk clear the store refused is not kept to be written later
  (task-48b10c6eb7ec20c5, task-8513709a4e52f781; #27533 review r5, N1 and N2).

  The desk unsets an emptied language (B06), and the field or object it
  leaves blank with it. When that save is refused, the field stays as stored:
  the next post, of another field, writes only that field, and undo after it
  takes back only that post.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.DeskRefusedClearTest.Halt
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  defp lt(name),
    do: %{
      "name" => name,
      "title" => name,
      "type" => "localizedText",
      "languages" => ["nob", "eng"],
      "fallbackChain" => ["nob", "eng"]
    }

  defp str(name), do: %{"name" => name, "title" => name, "type" => "string"}

  defp comp(name, fields),
    do: %{"name" => name, "title" => name, "type" => "composite", "fields" => fields}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "refused_clear_#{n}"

    fields = [
      str("title"),
      lt("cap"),
      comp("comp", [lt("cap"), str("note"), str("nul")]),
      comp("deep", [comp("inner", [lt("cap"), str("n")])]),
      str("notes")
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Refused #{n}",
          "visibility" => "public",
          "fields" => fields
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-rc-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-rc", @dataset, ~w(read write admin), ws_id)

    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([Halt])
    :persistent_term.put(Halt, false)

    on_exit(fn ->
      Barkpark.PluginEnv.restore(prior)
      :persistent_term.put(Halt, false)
    end)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "rc-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.put(content, "notes", "0")},
        @dataset
      )

    id
  end

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  # The draft row as the store holds it, jsonb text.
  defp row(c, id) do
    %{rows: [[text]]} =
      Barkpark.Repo.query!(
        "select content::text from documents where type = $1 and doc_id = $2 and dataset = $3",
        [c.type, "drafts." <> id, @dataset]
      )

    text
  end

  # The browser's `_target`: a top-level input's name split, a nested
  # input's path name whole.
  defp change(view, name, value, also \\ %{}) do
    view
    |> form(@form, Map.put(also, name, value))
    |> render_change(%{"_target" => target(name)})
  end

  defp target(name) do
    case Regex.run(~r/^doc\[([^\]]+)\]$/, name) do
      [_, key] -> ["doc", key]
      _ -> [name]
    end
  end

  defp undo(view, c, id, redo \\ false) do
    mark = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, id)}
    render_hook(view, "desk-undo", Map.put(mark, "redo", redo))
    render(view)
  end

  # A language is drawn as a text area: its value is its body.
  defp text_value(view, name) do
    html = view |> element(~s(#{@form} textarea[name="#{name}"])) |> render()
    [_, value] = Regex.run(~r/>\n?([^<]*)<\/textarea>/, html)
    value
  end

  defp refused(view, name) do
    :persistent_term.put(Halt, true)
    html = change(view, name, "")
    :persistent_term.put(Halt, false)
    html
  end

  test "a refused clear of a whole top-level field is not written by the next post, and undo takes back only that post",
       c do
    deep = %{"inner" => %{"cap" => %{"nob" => "dn"}}}
    id = doc!(c, %{"deep" => deep})
    view = desk(c, id)

    refused(view, "doc[deep].inner.cap.nob")
    assert stored(c, id)["deep"] == deep

    change(view, "doc[notes]", "n1")
    assert stored(c, id)["notes"] == "n1"
    assert stored(c, id)["deep"] == deep, "the refused clear was written by the post of notes"

    undo(view, c, id)
    assert stored(c, id)["notes"] == "0"
    assert stored(c, id)["deep"] == deep
  end

  test "a refused clear of a top-level language field is not written by the next post", c do
    cap = %{"nob" => "cn"}
    id = doc!(c, %{"cap" => cap})
    view = desk(c, id)

    html = refused(view, "doc[cap].nob")

    # The field is drawn as stored again, and the save region says why.
    assert text_value(view, "doc[cap].nob") == "cn"
    assert html =~ "held"
    refute html =~ "Not saved"

    change(view, "doc[notes]", "n1")
    assert stored(c, id)["notes"] == "n1"
    assert stored(c, id)["cap"] == cap

    undo(view, c, id)
    assert stored(c, id)["notes"] == "0"
    assert stored(c, id)["cap"] == cap
  end

  test "after a refused clear of a language, the next post leaves the object as stored (no cap: null)",
       c do
    id = doc!(c, %{"comp" => %{"cap" => %{"nob" => "cn", "eng" => "ce"}, "note" => "nn"}})
    view = desk(c, id)

    change(view, "doc[comp].cap.nob", "")
    Process.sleep(650)
    before = stored(c, id)["comp"]
    assert before == %{"cap" => %{"eng" => "ce"}, "note" => "nn"}

    refused(view, "doc[comp].cap.eng")
    change(view, "doc[notes]", "n1")
    assert stored(c, id)["notes"] == "n1"
    assert stored(c, id)["comp"] == before
    refute row(c, id) =~ ~s("cap": null)
  end

  test "a page that still shows the refused clear does not write it with the next post", c do
    deep = %{"inner" => %{"cap" => %{"nob" => "dn"}}}
    id = doc!(c, %{"deep" => deep})
    view = desk(c, id)

    refused(view, "doc[deep].inner.cap.nob")

    # The input had the focus when the refusal came back, so the browser kept
    # it empty, and it posts it so with the next change.
    change(view, "doc[notes]", "n1", %{"doc[deep].inner.cap.nob" => ""})

    assert stored(c, id)["notes"] == "n1"
    assert stored(c, id)["deep"] == deep
  end

  test "the same field cleared again once the store takes it is written", c do
    deep = %{"inner" => %{"cap" => %{"nob" => "dn"}}}
    id = doc!(c, %{"deep" => deep})
    view = desk(c, id)

    refused(view, "doc[deep].inner.cap.nob")
    change(view, "doc[deep].inner.cap.nob", "")
    refute Map.has_key?(stored(c, id), "deep")
  end
end
