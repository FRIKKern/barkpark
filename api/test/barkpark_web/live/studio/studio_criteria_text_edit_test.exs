defmodule BarkparkWeb.Studio.StudioCriteriaTextEditTest do
  @moduledoc """
  pds-w25-backlog-studio-criteria-text-edit — the RUNTIME probe the row asked
  for and never got: mount Studio authenticated, edit one criterion's text
  through the Classic form, and re-read the persisted document.

  The row's premise: `arrayOf`-of-`composite` inputs are named
  `doc[acceptance_criteria][0].criterion`, `Plug.Conn.Query.decode/1` does not
  nest through the `.`, so the key arrives FLAT and outside `%{"doc" => …}`,
  and the edit is discarded while the editor says Saved.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  defp seed_task_schema! do
    schema = Barkpark.Tasks.task_schema(@dataset)

    attrs =
      schema
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    {:ok, _} = Content.upsert_schema(attrs, @dataset)
    :ok
  end

  # The criteria list the probe edits. Row 0 carries `merge_gate: true` — an
  # UNKNOWN key: the schema's composite declares only criterion/met/evidence,
  # so nothing renders an input for it and only the save path can preserve it.
  defp criteria do
    [
      %{
        "criterion" => "ORIGINAL ZERO",
        "met" => false,
        "evidence" => "",
        "merge_gate" => true
      },
      %{"criterion" => "ORIGINAL ONE", "met" => false, "evidence" => ""}
    ]
  end

  defp seed_task_doc!(slug) do
    {:ok, doc} =
      Content.upsert_document(
        "task",
        %{
          "doc_id" => slug,
          "title" => "criteria probe",
          "status" => "published",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => criteria()
          }
        },
        @dataset,
        source: :api
      )

    doc
  end

  defp editor_conn! do
    raw = "w25-crit-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "w25-crit", @dataset, ["read", "write", "admin"])

    scoped_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
  end

  defp reread!(slug) do
    case Content.get_document("drafts.#{slug}", "task", @dataset) do
      {:ok, d} ->
        d

      _ ->
        {:ok, d} = Content.get_document(slug, "task", @dataset)
        d
    end
  end

  setup do
    seed_task_schema!()
    slug = "w25-crit-task-#{System.unique_integer([:positive])}"
    seed_task_doc!(slug)
    {:ok, slug: slug}
  end

  test "the Classic form renders dotted criterion inputs", %{slug: slug} do
    conn = editor_conn!()
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task/#{slug}"))

    refute html =~ "studio-unresolved-document-notice"

    assert html =~ ~s(name="doc[acceptance_criteria][0].criterion"),
           "the criterion input is not named as the row claims; wire premise changed"
  end

  test "a criterion text edit persists and unknown keys survive", %{slug: slug} do
    conn = editor_conn!()
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task/#{slug}"))

    assert html =~ ~s(name="doc[acceptance_criteria][0].criterion")

    # THE WIRE SHAPE, not a hand-nested map. This is what the browser
    # serializes for the two composite rows plus the title, decoded exactly as
    # Phoenix decodes it.
    query =
      [
        "doc[title]=criteria+probe",
        "doc[acceptance_criteria][0].criterion=EDITED+ZERO",
        "doc[acceptance_criteria][0].met=false",
        "doc[acceptance_criteria][0].evidence=",
        "doc[acceptance_criteria][1].criterion=ORIGINAL+ONE",
        "doc[acceptance_criteria][1].met=false",
        "doc[acceptance_criteria][1].evidence="
      ]
      |> Enum.join("&")

    wire = Plug.Conn.Query.decode(query)

    assert Map.has_key?(wire, "doc[acceptance_criteria][0].criterion"),
           "the decode no longer leaves the dotted key flat: #{inspect(Map.keys(wire))}"

    # A real edit fires phx-change first (that is what carries `_target`), then
    # the submit. Reproduce both.
    render_change(
      view,
      "autosave",
      Map.put(wire, "_target", ["doc[acceptance_criteria][0].criterion"])
    )

    render_submit(view, "save", wire)

    stored = reread!(slug) |> Map.get(:content) |> Map.get("acceptance_criteria")

    assert is_list(stored),
           "acceptance_criteria is no longer a list after a Studio save: #{inspect(stored)}"

    assert length(stored) == 2,
           "the criteria list changed length across a Studio save: #{inspect(stored)}"

    # c1 — the edited text persists.
    assert Enum.at(stored, 0)["criterion"] == "EDITED ZERO",
           "the criterion text did NOT persist; stored row 0 = #{inspect(Enum.at(stored, 0))}"

    # c1 — the untouched sibling row is unharmed.
    assert Enum.at(stored, 1)["criterion"] == "ORIGINAL ONE",
           "the untouched sibling criterion was damaged: #{inspect(Enum.at(stored, 1))}"

    # c2 — an unknown key on the EDITED row survives byte-identical.
    assert Enum.at(stored, 0)["merge_gate"] == true,
           "merge_gate was stripped from the edited criterion: #{inspect(Enum.at(stored, 0))}"
  end
end
