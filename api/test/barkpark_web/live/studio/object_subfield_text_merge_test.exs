defmodule BarkparkWeb.Studio.ObjectSubfieldTextMerge.HaltOnFail do
  @moduledoc false
  # A before_save hook that refuses any write whose `meta.label` holds
  # "FAIL": the editor's save answers "Save cancelled", and the typing is
  # held unsaved in the form.
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    label = get_in(doc, ["content", "meta", "label"])
    if is_binary(label) and String.contains?(label, "FAIL"), do: {:halt, "test"}, else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.ObjectSubfieldTextMergeTest do
  @moduledoc """
  task-71ff11d4e7374985: two people type in the same text subfield of an
  object (`meta.label`). A top-level free-text field merges both people's
  words (`TextRebase`, `RemoteValues`, `UnsavedBases`); the subfield was the
  last writer's alone: another editor's save was never told to the page for
  it (`bp:form-remote-values` named top-level fields only), so a post typed
  from the older label carried no base, and it was written over the other's
  words. Held unsaved words in the object were a conflict whatever the other
  editor changed in it.

  TanStack keys every pending edit by its path (`meta.label`) and merges
  each one as text (barkpark-studio edit-bases.ts `rebase`). The same here,
  by path: the push names `doc[meta].label` with its numbers, the post's
  base is the value the page reports for it, and held words in the object
  merge subfield by subfield.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ObjectSubfieldTextMerge.HaltOnFail

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @label "doc[meta].label"
  @flat %{"title" => "T0", "notes" => "n0"}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "subfield_text_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Subfield texts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "code", "title" => "Code", "type" => "string"},
                %{"name" => "label", "title" => "Label", "type" => "string"}
              ]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "subfield-text-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"code" => "c0", "label" => "one two three"}, "notes" => "n0"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "subfield-text-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "subfield-text", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    prior = Barkpark.PluginEnv.capture()
    Barkpark.PluginEnv.put!([HaltOnFail])
    on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A post as the page sends it: every input, the object's subfields under
  # their dotted names, `target` the input that changed, `seen` its
  # `_bp_seen` as bp-array-focus.js keeps it.
  defp posts(view, target, meta, seen \\ %{}) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => @flat,
      "doc[meta].code" => meta["code"],
      "doc[meta].label" => meta["label"],
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    })
  end

  # The numbers of the push A was sent for the label, `[was, value]`, or
  # nil when no push named it.
  defp label_seqs(view) do
    render(view)

    try do
      assert_push_event(view, "bp:form-remote-values", %{values: %{@label => _}} = payload, 500)
      get_in(payload, [:seqs, @label])
    rescue
      ExUnit.AssertionError -> nil
    end
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["meta"]
  end

  # A's label typing did not land: "FAIL" is refused by the hook, and the
  # form holds it unsaved.
  defp held_label(a, label) do
    posts(a, @label, %{"code" => "c0", "label" => label})

    assert eventually(fn ->
             MapSet.member?(assigns(a).editor_unsaved_keys || MapSet.new(), "meta")
           end)

    assert assigns(a).editor_form["meta"]["label"] == label
  end

  test "the label is a subfield input under its dotted name", c do
    a = open(c, :desk)
    assert has_element?(a, ~s(#editor-form input[name="#{@label}"]))
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A and B type different words of meta.label: both land", c do
      a = open(c, @surface)
      b = open(c, @surface)

      posts(b, @label, %{"code" => "c0", "label" => "one two three B"})
      assert eventually(fn -> stored(c)["label"] == "one two three B" end)

      # A was typing, so its label still shows the text it typed from: the
      # page reports the number of that value.
      seqs = label_seqs(a)
      seen = if seqs, do: %{@label => hd(seqs)}, else: %{}
      posts(a, @label, %{"code" => "c0", "label" => "A one two three"}, seen)

      assert eventually(fn -> stored(c)["label"] != "one two three B" end)
      assert stored(c) == %{"code" => "c0", "label" => "A one two three B"}
      assert eventually(fn -> assigns(a).editor_form["meta"]["label"] == "A one two three B" end)
    end

    test "#{surface}: A's held words in the label merge with B's, no banner", c do
      a = open(c, @surface)
      b = open(c, @surface)
      held_label(a, "one two three FAIL")

      posts(b, @label, %{"code" => "c0", "label" => "B one two three"})
      assert eventually(fn -> stored(c)["label"] == "B one two three" end)

      assert eventually(fn ->
               assigns(a).editor_form["meta"]["label"] == "B one two three FAIL"
             end)

      assert assigns(a).doc_conflict == false
      refute has_element?(a, @banner)
    end

    test "#{surface}: A's held label under B's code change: both kept, no banner", c do
      a = open(c, @surface)
      b = open(c, @surface)
      held_label(a, "one two three FAIL")

      posts(b, "doc[meta].code", %{"code" => "cB", "label" => "one two three"})
      assert eventually(fn -> stored(c)["code"] == "cB" end)

      assert eventually(fn ->
               assigns(a).editor_form["meta"] == %{
                 "code" => "cB",
                 "label" => "one two three FAIL"
               }
             end)

      refute has_element?(a, @banner)
    end

    # Control (passes on main): both rewrote the same words.
    test "#{surface}: an overlap in the label shows the banner and keeps A's words", c do
      a = open(c, @surface)
      b = open(c, @surface)
      held_label(a, "one FAIL three")

      posts(b, @label, %{"code" => "c0", "label" => "one 2 three"})
      assert eventually(fn -> stored(c)["label"] == "one 2 three" end)

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["meta"]["label"] == "one FAIL three"
      assert has_element?(a, @banner)
    end
  end

  # Control (passes on main): a page that reports no number for the label
  # (an older bp-array-focus.js, no `v`) stands as sent, as a top-level field.
  test "a post with no number from an older page stands as sent", c do
    a = open(c, :desk)
    b = open(c, :desk)
    posts(b, @label, %{"code" => "c0", "label" => "one two three B"})
    assert eventually(fn -> stored(c)["label"] == "one two three B" end)

    a
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [@label],
      "doc" => @flat,
      "doc[meta].code" => "c0",
      "doc[meta].label" => "A one two three"
    })

    assert eventually(fn -> stored(c)["label"] == "A one two three" end)
  end
end
