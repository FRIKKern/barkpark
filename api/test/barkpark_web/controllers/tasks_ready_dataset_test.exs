defmodule BarkparkWeb.TasksReadyDatasetTest do
  @moduledoc """
  THE ONE RULE at the LISTING door (task-0084e191d406de96, the residual of
  task-49eef068420df918 C1 that PR #16474 left open by design).

  The rule is stated once, in `Barkpark.Tasks.TwinResolver`'s moduledoc. This
  file proves its two consequences for `GET /v1/tasks/ready`:

    * C0 — `?dataset=` is HONOURED (it was parsed nowhere: `ready/2` built its
      opts without `:dataset` and `Queue.maybe_filter_dataset/2` no-opped on the
      nil, so `?dataset=production` and `?dataset=aker-brygge` returned the SAME
      1000 rows on guerrilla, measured 2026-09-06), and the default with no
      dataset named is STATED in the response rather than silently global.
    * C1 — a doc_id living in two datasets of one workspace+project appears AT
      MOST ONCE. Rules 1+2 resolve it when one row wins the tier; rule 3
      withholds it when the tier ties, and it is then named ONCE in
      `page.dataset_ambiguous` with the dataset set it spans. That is the
      listing shape of the 409 the by-id doors raise — a listing must not refuse
      the whole page over one ambiguous id.

  RED on origin/main: `?dataset=` ignored, and a twinned id served TWICE in one
  page (`akbr-feedback-2026-08-epic` did, live).
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-ready-dataset"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-ready-dataset", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for dataset <- [@primary, @secondary], schema_def <- Tasks.schema_definitions(dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, dataset, scope)
    end

    %{scope: scope, phase_id: uniq("phase-ready-dataset")}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A PUBLISHED task row, seeded by renaming a draft in place — the authoring
  # wall's label spine (a 20+ char description and 1-12 registered tags) is not
  # satisfiable from a test database, and the shape under measurement is the
  # ROW, not the publish path. Same fixture as `BarkparkWeb.TasksTwinOneRuleTest`.
  defp mk_published!(doc_id, dataset, scope, phase_id, extra \\ %{}) do
    mk_row!(doc_id, doc_id, dataset, scope, phase_id, "published", extra)
  end

  # The `drafts.<id>` twin — tier 0, the row rules 1+2 never pick while a
  # published-spelling row exists.
  defp mk_draft!(doc_id, dataset, scope, phase_id, extra) do
    mk_row!("drafts." <> doc_id, doc_id, dataset, scope, phase_id, "draft", extra)
  end

  defp mk_row!(slug, doc_id, dataset, scope, phase_id, status, extra) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "parent_id" => phase_id,
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ]
        },
        extra
      )

    {:ok, draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "#{doc_id} (#{dataset} #{System.unique_integer([:positive])})",
          "content" => content
        },
        dataset,
        scope
      )

    {1, _} =
      from(d in Document, where: d.id == ^draft.id)
      |> Repo.update_all(set: [doc_id: slug, status: status])

    Repo.get!(Document, draft.id)
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp ready(params) do
    authed(build_conn())
    |> get(~p"/v1/tasks/ready", params)
    |> json_response(200)
  end

  defp doc_ids(body), do: Enum.map(body["docs"], & &1["doc_id"])

  describe "C0 — a dataset the caller did not ask for cannot contribute rows" do
    test "?dataset= returns only that dataset's rows", %{scope: scope, phase_id: phase_id} do
      prod = uniq("ready-ds-prod")
      alt = uniq("ready-ds-alt")
      _ = mk_published!(prod, @primary, scope, phase_id)
      _ = mk_published!(alt, @secondary, scope, phase_id)

      # RED on origin/main: `?dataset=` reached nothing, so BOTH ids came back
      # under EITHER value — the identical-page result measured live.
      primary_page = ready(%{"phase_id" => phase_id, "dataset" => @primary})
      secondary_page = ready(%{"phase_id" => phase_id, "dataset" => @secondary})

      assert doc_ids(primary_page) == [prod]
      assert doc_ids(secondary_page) == [alt]
    end

    test "the page STATES which dataset(s) it spans, named or not", %{
      scope: scope,
      phase_id: phase_id
    } do
      prod = uniq("ready-span-prod")
      alt = uniq("ready-span-alt")
      _ = mk_published!(prod, @primary, scope, phase_id)
      _ = mk_published!(alt, @secondary, scope, phase_id)

      unnamed = ready(%{"phase_id" => phase_id})

      assert unnamed["page"]["dataset"] == nil
      assert unnamed["page"]["dataset_scope"] == "all-datasets-in-scope"
      assert unnamed["page"]["datasets"] == Enum.sort([@primary, @secondary])

      # In `page`, never in `help[]`: a read envelope on this route carries no
      # help[] (axi-s4 R5, pinned by tasks_controller_test.exs), and the
      # brief-truncation line is that rule's one standing exception.
      refute Enum.any?(unnamed["help"] || [], &(&1 =~ "dataset"))

      named = ready(%{"phase_id" => phase_id, "dataset" => @primary})

      assert named["page"]["dataset"] == @primary
      assert named["page"]["dataset_scope"] == "named"
      assert named["page"]["datasets"] == [@primary]
    end
  end

  describe "C1 — a doc_id appears at most once, whatever the caller named" do
    test "a TIED cross-dataset twin is withheld and NAMED once, not served twice", %{
      scope: scope,
      phase_id: phase_id
    } do
      doc_id = uniq("ready-twin")
      _ = mk_published!(doc_id, @primary, scope, phase_id)
      _ = mk_published!(doc_id, @secondary, scope, phase_id, %{"dataset_twin_intended" => true})

      page = ready(%{"phase_id" => phase_id})

      # RED on origin/main: TWO rows, one per dataset, in ONE page.
      assert doc_ids(page) == []

      assert page["page"]["dataset_ambiguous"] == [
               %{"doc_id" => doc_id, "datasets" => Enum.sort([@primary, @secondary])}
             ]
    end

    test "naming a dataset is the way through — the row comes back, once", %{
      scope: scope,
      phase_id: phase_id
    } do
      doc_id = uniq("ready-twin-named")
      _ = mk_published!(doc_id, @primary, scope, phase_id)
      _ = mk_published!(doc_id, @secondary, scope, phase_id, %{"dataset_twin_intended" => true})

      page = ready(%{"phase_id" => phase_id, "dataset" => @secondary})

      assert doc_ids(page) == [doc_id]
      assert page["page"]["dataset_ambiguous"] == []
    end

    test "a UNIQUE winning tier resolves — the published row answers, the draft twin does not",
         %{scope: scope, phase_id: phase_id} do
      doc_id = uniq("ready-tier")
      _ = mk_published!(doc_id, @primary, scope, phase_id)
      _ = mk_draft!(doc_id, @secondary, scope, phase_id, %{"dataset_twin_intended" => true})

      page = ready(%{"phase_id" => phase_id})

      # Rules 1+2, not a dataset comparison: the published-spelling row wins its
      # tier outright, so there is nothing to refuse and exactly one row answers.
      assert doc_ids(page) == [doc_id]
      assert page["page"]["dataset_ambiguous"] == []
      assert page["page"]["datasets"] == [@primary]
    end

    test "an ordinary single-dataset task is untouched", %{scope: scope, phase_id: phase_id} do
      doc_id = uniq("ready-plain")
      _ = mk_published!(doc_id, @primary, scope, phase_id)

      page = ready(%{"phase_id" => phase_id})

      assert doc_ids(page) == [doc_id]
      assert page["page"]["dataset_ambiguous"] == []
    end
  end
end
