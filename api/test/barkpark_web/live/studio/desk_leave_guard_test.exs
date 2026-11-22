defmodule BarkparkWeb.Studio.DeskLeaveGuard.HaltOnFail do
  @moduledoc false
  # Refuses any write whose title holds "FAIL": the title typing is held
  # unsaved in the form.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    title = get_in(doc, ["title"]) || get_in(doc, ["content", "title"])
    if is_binary(title) and String.contains?(title, "FAIL"), do: {:halt, "test"}, else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.DeskLeaveGuardTest do
  @moduledoc """
  task-33cbb6269c8823ad: a desk pane navigation from a document with a held
  field (typing a save refused, or rich text held over another editor's
  rewrite) dropped what was held with no word: the next document's form
  replaced it. A tab close or reload asked only over "Save failed".

  The edit pane now carries `data-desk-held`, the question `bp-desk.js` asks
  before a link leaves the document and before the tab closes or reloads
  (TanStack's `hasUnsaved()` beforeunload, `lib/edits.ts`), and
  `data-desk-held-doc`, the document a link may keep. Neither is drawn while
  nothing is held.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias BarkparkWeb.Studio.Desk.LeaveGuard
  alias BarkparkWeb.Studio.DeskLeaveGuard.HaltOnFail

  @pane "[data-pane-editing]"
  @held ~s([data-pane-editing][data-desk-held])

  setup %{conn: conn} do
    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([HaltOnFail])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)
    setup_doc(conn)
  end

  # The page's own post: every value the form holds, with the title typed.
  defp post_title(view, title) do
    view
    |> form("#editor-form", %{"doc" => %{"title" => title}})
    |> render_change(%{"_target" => ["doc", "title"]})
  end

  defp held_attr(view, name) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(@pane)
      |> LazyHTML.attribute(name)

    value
  end

  test "a held title: the pane asks before leaving, naming the field", c do
    a = open(c)
    refute has_element?(a, @held)

    post_title(a, "T0 FAIL")

    assert eventually(fn -> has_element?(a, @held) end)
    assert held_attr(a, "data-desk-held") =~ "Not saved: Title"
    assert held_attr(a, "data-desk-held-doc") == c.id
  end

  test "held rich text: the pane asks before leaving, naming the field", c do
    a = open(c)
    b = open(c)
    refute has_element?(a, @held)

    held_by_clash(a, b, c)

    assert has_element?(a, @held)
    assert held_attr(a, "data-desk-held") =~ "Not saved: Meta"
  end

  test "control: a save that lands holds nothing, and the pane does not ask", c do
    a = open(c)
    post_title(a, "T0 FAIL")
    assert eventually(fn -> has_element?(a, @held) end)

    post_title(a, "T0 fixed")

    assert eventually(fn -> not has_element?(a, @held) end)
  end

  test "the question in Norwegian" do
    assigns = %{
      editor_unsaved_keys: MapSet.new(["title"]),
      editor_schema: %{fields: [%{"name" => "title", "title" => "Tittel"}]}
    }

    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      assert LeaveGuard.message(assigns) ==
               "Ikke lagret: Tittel. Vil du forlate dokumentet likevel? Det du skrev der, går tapt."
    end)
  end
end
