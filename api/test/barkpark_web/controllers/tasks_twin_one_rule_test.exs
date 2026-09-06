defmodule BarkparkWeb.TasksTwinOneRuleTest do
  @moduledoc """
  THE ONE RULE at the HTTP door (task-49eef068420df918 C0).

  The rule is stated once in `Barkpark.Tasks.TwinResolver`'s moduledoc. This file
  proves the wire contract of its rule 3: `GET /v1/tasks/:doc_id` for an id that
  lives in two datasets answers **409 `ambiguous_dataset`** naming both, and
  `?dataset=` — which this route used to IGNORE (proven live on guerrilla) — is
  the caller's way through.

  RED on origin/main: 200 with the alphabetically-first dataset's row, silently.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-twin-one-rule"
  @primary "production"
  @secondary "aker-brygge"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-twin", "test", ["read", "write", "admin"])
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

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Same fixture shape as `Barkpark.Tasks.TwinOneRuleTest` — see the comment
  # there for why a published row is seeded by renaming a draft in place.
  defp mk_published!(doc_id, dataset, scope, extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
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
      |> Repo.update_all(set: [doc_id: doc_id, status: "published"])

    Repo.get!(Document, draft.id)
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  describe "GET /v1/tasks/:doc_id for a doc_id in two datasets" do
    setup %{scope: scope} do
      doc_id = uniq("http-twin")
      primary = mk_published!(doc_id, @primary, scope)

      secondary =
        mk_published!(doc_id, @secondary, scope, %{"dataset_twin_intended" => true})

      %{doc_id: doc_id, primary: primary, secondary: secondary}
    end

    test "refuses with 409 ambiguous_dataset naming every dataset", %{
      conn: conn,
      doc_id: doc_id
    } do
      # RED on origin/main: 200, answering from @secondary ("aker-brygge" sorts
      # first) while `bp doc patch` wrote @primary — two doors, one id, two rows.
      #
      # `assert_error_sent/2` rather than `json_response/2`: the refusal is a
      # RAISE at the resolver chokepoint (see `Barkpark.Tasks.AmbiguousTwinError`
      # on why it is not a return value), so this measures the WHOLE wire path —
      # `Plug.Exception`'s 409 AND `BarkparkWeb.ErrorJSON`'s pass-through, which
      # is what keeps the body from collapsing to a generic `internal_error`.
      {409, _headers, body} =
        assert_error_sent(409, fn ->
          get(authed(conn), ~p"/v1/tasks/#{doc_id}")
        end)

      assert %{"error" => error} = Jason.decode!(body)
      assert error["code"] == "ambiguous_dataset"
      assert error["details"]["doc_id"] == doc_id
      assert error["details"]["datasets"] == Enum.sort([@primary, @secondary])
      assert error["hint"] =~ "dataset"
    end

    test "?dataset= is HONOURED — it names the row, and each names a different one",
         %{conn: conn, doc_id: doc_id, primary: primary, secondary: secondary} do
      for {dataset, expected} <- [{@primary, primary}, {@secondary, secondary}] do
        resp =
          authed(build_conn())
          |> get(~p"/v1/tasks/#{doc_id}?dataset=#{dataset}")
          |> json_response(200)

        assert resp["doc"]["rev"] == expected.rev,
               "?dataset=#{dataset} did not resolve that dataset's row"
      end
    end
  end

  test "an ordinary single-row task is unaffected", %{conn: conn, scope: scope} do
    doc_id = uniq("http-single")
    only = mk_published!(doc_id, @primary, scope)

    resp = authed(conn) |> get(~p"/v1/tasks/#{doc_id}") |> json_response(200)
    assert resp["doc"]["rev"] == only.rev
  end
end
