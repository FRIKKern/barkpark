defmodule BarkparkWeb.TaskAdjudicationTripleRoundTripTest do
  @moduledoc """
  PDS wave 29, c4 — the declared adjudication triple survives the whole write
  path and reads back on the PUBLISHED perspective.

  A schema declaration is worth nothing if the keys it declares do not actually
  survive the doors a producer uses. This drives the real HTTP surface end to
  end — `POST /v1/data/mutate/:dataset` create → patch → publish, then
  `GET /v1/data/doc/:dataset/task/:id?perspective=published` — and asserts that
  `disposition`, `reopen_trigger` and `disposition_rerun` are all three present
  and byte-identical on the published row.

  THE PUBLISHED PERSPECTIVE IS THE POINT, not an incidental read. A create
  lands on `drafts.<id>`; a consumer reading the published perspective sees a
  DIFFERENT row, and "the field persists" measured on the draft says nothing
  about what a published reader gets. Wave 29 proved live that a create → patch
  → publish sequence can carry content past a birth-scoped fence, so the
  published row is exactly where this has to be measured.

  The patch deliberately carries a NON-adjudication field: the raw mutate door
  refuses a direct change of `disposition`/`disposition_rerun` on a live task
  (`Mutations.ensure_disposition_via_verb/4` — that is a different slice's
  fence and this test must not route around it). What is proven here is that an
  unrelated patch does not silently drop the triple on its way through the
  merge.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Stage

  @dataset "production"
  @token "barkpark-test-adjudication-round-trip-token"

  setup %{conn: conn} do
    {:ok, _} = Auth.create_token(@token, "adjudication round trip", "test", ["read", "write"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    # The publish wall (`Content.Lifecycle` @walled_types) refuses a task
    # publish without a non-trivial description and 1-12 registered weighted
    # tags — so this round trip carries the standard fixture spine.
    LabelFixtures.register_tags!(@dataset)

    %{conn: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token), scope: scope}
  end

  defp mutate(conn, ops) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => ops}))
  end

  test "the declared triple survives create → patch → publish and reads back published",
       %{conn: conn} do
    id = "adjudication-round-trip-#{System.unique_integer([:positive])}"
    trigger = "when the Bokbasen contract is renegotiated"
    rerun = "git grep -n disposition origin/main -- api/lib/barkpark/tasks/schema.ex"

    # The three keys under test are the ones the schema now DECLARES — read
    # from Stage so this test cannot drift from the declaration either.
    disposition_key = Stage.disposition_key()
    trigger_key = Stage.reopen_trigger_key()
    rerun_key = Stage.disposition_rerun_key()

    # A born-adjudicated park: a complete adjudication, so the birth fence
    # accepts it (a hollow park would be 422 — task_birth_fence_test.exs).
    create =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => id,
            "_type" => "task",
            "title" => id,
            "content" =>
              Map.merge(LabelFixtures.weighted_labels(), %{
                "kind" => "task",
                "lifecycle_status" => "open",
                disposition_key => "parked",
                trigger_key => trigger,
                rerun_key => rerun
              })
          }
        }
      ])

    assert create.status == 200, "create failed: #{create.resp_body}"

    draft_id = "drafts." <> id

    # PATCH — an unrelated field, through the same raw door. The triple must
    # ride the merge untouched.
    patch =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => draft_id,
            "type" => "task",
            "set" => %{"assignee" => "round-trip-api-w8"}
          }
        }
      ])

    assert patch.status == 200, "patch failed: #{patch.resp_body}"

    publish = mutate(conn, [%{"publish" => %{"id" => id, "type" => "task"}}])
    assert publish.status == 200, "publish failed: #{publish.resp_body}"

    body =
      conn
      |> get("/v1/data/doc/#{@dataset}/task/#{id}?perspective=published")
      |> json_response(200)

    # `GET /v1/data/doc` flattens content onto the result alongside the `_`
    # envelope keys; `_draft == false` is what proves this is the PUBLISHED row
    # and not the `drafts.` one the create landed on.
    content = body["result"]

    assert is_map(content), "no published document in: #{inspect(body)}"
    assert content["_draft"] == false, "read a DRAFT, not the published perspective"
    assert content["_id"] == id

    assert content["assignee"] == "round-trip-api-w8",
           "the published read did not carry the patch — wrong row or wrong perspective"

    # THE ASSERTION: all three declared keys, on the PUBLISHED perspective.
    assert content[disposition_key] == "parked"
    assert content[trigger_key] == trigger
    assert content[rerun_key] == rerun

    # And what the schema declares is what came back — no declared key of the
    # triple is missing from the published read.
    declared =
      Tasks.task_schema(@dataset).fields
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(&1 in [disposition_key, trigger_key, rerun_key]))

    assert Enum.sort(declared) == Enum.sort([disposition_key, trigger_key, rerun_key]),
           "the schema stopped declaring part of the triple"

    for key <- declared do
      assert Map.has_key?(content, key),
             "#{key} is declared but absent from the published read: #{inspect(Map.keys(content))}"
    end
  end
end
