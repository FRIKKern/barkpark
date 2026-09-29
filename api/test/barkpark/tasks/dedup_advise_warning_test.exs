defmodule Barkpark.Tasks.DedupAdviseWarningTest do
  @moduledoc """
  THE CREATE GATE'S ADVISE BAND REACHES THE AUTHOR (task-a0cd11dd35788460).

  `Tasks.Dedup.gate/4` used to return `:ok` on an allowed create and drop the
  advise list — it fed only the optional LLM judge. spd-b37 re-filed spd-b27's
  serif-stack finding in different words; the pair scores 0.2833, under both
  the old 0.30 advise floor and the 0.55 refuse floor, so the second create came
  back a clean 2xx with nothing said.

  The advise band now rides the mutate SUCCESS envelope as a `possible_duplicate`
  warning — the key, severity and shape the publish wall (`Content.DedupWall`)
  already uses — and `bp task create` prints every `warnings[]` entry to stderr.

  THIS FILE MEASURES THE WIRE: the creates go through `POST /v1/data/mutate` and
  the assertions read the decoded response body, so a controller that stopped
  draining the accumulator would red here even with the gate intact. The texts
  are the two rows' STORED title + description (fixture below), not a
  hand-written paraphrase tuned to land in the band.

  Three directions: the paraphrased pair is WARNED and still CREATED; an
  unrelated create carries NO such warning; and the threshold is what makes the
  difference — the same pair at the old 0.30 floor draws no advise at all.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Similarity

  @dataset "test"
  @code "possible_duplicate"

  @fixture "test/support/fixtures/dedup/spd_b27_b37.json"
           |> File.read!()
           |> Jason.decode!()

  @earlier @fixture["earlier"]
  @later @fixture["later"]

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    register_task_schemas!()
    :ok
  end

  describe "an allowed create in the advise band carries a possible_duplicate warning" do
    test "spd-b37's text against spd-b27's is WARNED, not refused, and the row lands",
         %{conn: conn} do
      first = mutate(conn, [task_create(@earlier, "studio-space-priority-desk")])
      assert first.status == 200

      second =
        mutate(conn, [task_create(@later, "spd-b39-user-opened-inspector-shape-successor")])

      # Not refused: the duplicate gate's refusal is a 409 with no results.
      assert second.status == 200, "the create was refused: #{second.resp_body}"
      body = Jason.decode!(second.resp_body)
      assert [%{"id" => "drafts." <> _}] = body["results"]
      assert draft_row("drafts." <> @later["id"]), "the warned create must still LAND"

      warned = Enum.filter(body["warnings"] || [], &(&1["code"] == @code))

      assert length(warned) == 1,
             "expected one #{@code} warning naming #{@earlier["id"]}, got: " <>
               inspect(body["warnings"])

      [warning] = warned

      assert warning["severity"] == "warning"
      assert warning["message"] =~ @earlier["id"]
      assert warning["message"] =~ "similarity 0.2833"
      assert warning["message"] =~ "create went through"
    end
  end

  describe "the discrimination half" do
    test "a create with no near match carries no possible_duplicate warning", %{conn: conn} do
      assert mutate(conn, [task_create(@earlier, "studio-space-priority-desk")]).status == 200

      unrelated = %{
        "id" => "dedup-advise-unrelated",
        "title" => "Rotate the webhook signing secret on the billing relay",
        "description" => "The relay still signs outbound webhooks with the key minted at launch."
      }

      resp = mutate(conn, [task_create(unrelated, "some-other-epic")])
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Enum.filter(body["warnings"] || [], &(&1["code"] == @code)) == [],
             "an unrelated create was warned: #{inspect(body["warnings"])}"
    end

    test "the pair sits between the new and the old advise floor — 0.28 catches it, 0.30 did not" do
      new = scored(@later, "spd-b39-user-opened-inspector-shape-successor")
      old = scored(@earlier, "studio-space-priority-desk")

      assert Similarity.thresholds() == %{refuse: 0.55, advise: 0.28}
      assert_in_delta Similarity.similarity(new, old), 0.2833, 0.0001

      assert [%{id: id, verdict: :advise, structural: :cross}] =
               Similarity.assess(new, [old]).advise

      assert id == @earlier["id"]
      assert Similarity.assess(new, [old], advise: 0.30).advise == []
    end
  end

  defp scored(row, parent) do
    %{id: row["id"], title: row["title"], description: row["description"], parent: parent}
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task_create(row, parent) do
    %{
      "create" => %{
        "_id" => row["id"],
        "_type" => "task",
        "title" => row["title"],
        "content" => %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "priority" => 2,
          "parent_id" => parent,
          "description" => row["description"],
          "acceptance_criteria" => [%{"criterion" => "the suite is green", "met" => false}]
        }
      }
    }
  end

  defp draft_row(doc_id) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task" and d.dataset == ^@dataset,
        select: d.doc_id
      )
    )
  end

  defp register_task_schemas! do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end
end
