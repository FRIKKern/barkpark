defmodule BarkparkWeb.MutateRevisionActorTest do
  @moduledoc """
  task-007fea89d2f229ce, criterion 1 — a revision written through the generic
  document door names the principal the SERVER authenticated.

  Measured live 2026-09-25: `bp task create --publish` (POST /v1/data/mutate,
  create + publish) wrote two revisions whose `actor_kind` / `actor_id` /
  `actor_label` / `actor_user_id` were all NULL, although the mutate door had
  resolved an api-token `CallerContext` for that very request. The context
  reached `Content.Writer` / `Content.Lifecycle` in `opts[:caller_context]`
  and stopped there: every `Broadcast.tap_broadcast/7` call passed only
  `opts[:user_id]` (nil for a token), and `tap_broadcast` called
  `save_revision/5`, whose actor-stamp argument defaulted to `%{}`.

  The arms, over the real HTTP doors:

    * STAMPED — mutate create + publish as an api token, then
      `GET /v1/data/history/:dataset/task/:id`: both revisions carry
      `actor_kind: "api_token"` and `actor_id` = the token's row id.
    * NOT CLIENT-CHOSEN — the create body's `content` also carries
      `actor_kind` / `actor_id` / `actor_label` naming somebody else (top-level
      keys are refused 422 by the door); the revision still names the token
      the request arrived on.
    * CONTROL — a revision written on the SAME row through the caller-less
      seam (`tap_broadcast/7`, the shape every pre-change write produced)
      reads back with all four actor keys PRESENT and `nil` — UNMEASURED,
      never `""`. Without it, "non-null on the new revisions" would also pass
      on a read that stamped every row, old and new alike.

  SHARED TEST DATABASE: every arm writes under a unique id and reads back only
  that id's history.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, LabelFixtures}
  alias Barkpark.Content.Broadcast

  @token "barkpark-test-mutate-revision-actor"
  @dataset "test"

  setup do
    {:ok, token} =
      Auth.create_token(
        @token,
        "test-mutate-revision-actor",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    LabelFixtures.register_tags!(@dataset)
    %{token_id: token.id}
  end

  defp authed do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "priority" => 2,
      "brief" => Barkpark.TaskBriefFixtures.brief(),
      "description" =>
        "A deliberately long description so the label spine is satisfied and " <>
          "the only variable under test is who the revision names.",
      "acceptance_criteria" => [%{"criterion" => "the revision names its writer", "met" => false}]
    }
    |> Map.merge(LabelFixtures.weighted_labels())
  end

  # `content_extra` merges INTO `content`: the door refuses unknown top-level
  # keys outright (422 unknown_fields), so `content` is the only place a client
  # can put an actor claim at all.
  defp create_and_publish!(id, content_extra \\ %{}) do
    create = %{
      "_id" => id,
      "_type" => "task",
      "title" => "probe #{id}",
      "content" => Map.merge(task_content(), content_extra)
    }

    resp =
      post(
        authed(),
        "/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{
          "mutations" => [%{"create" => create}, %{"publish" => %{"id" => id, "type" => "task"}}]
        })
      )

    # PRECONDITION: a refused batch writes no revision, and no revision would
    # otherwise read as "no actor".
    assert resp.status == 200, "mutate refused: #{resp.status} #{resp.resp_body}"
    :ok
  end

  defp history(id) do
    resp = get(authed(), "/v1/data/history/#{@dataset}/task/#{id}")
    assert resp.status == 200, "history: #{resp.status} #{resp.resp_body}"
    Jason.decode!(resp.resp_body)["revisions"]
  end

  defp by_action(revisions, action), do: Enum.filter(revisions, &(&1["action"] == action))

  test "mutate create + publish stamps the api token on both revisions", %{token_id: token_id} do
    id = uniq("rev-actor")
    create_and_publish!(id)

    revisions = history(id)
    [create] = by_action(revisions, "create")
    [publish] = by_action(revisions, "publish")

    for rev <- [create, publish] do
      assert rev["actor_kind"] == "api_token", "unstamped revision: #{inspect(rev)}"
      assert rev["actor_id"] == token_id
    end
  end

  test "an actor named in the request body is not what the revision records",
       %{token_id: token_id} do
    id = uniq("rev-actor-spoof")

    create_and_publish!(id, %{
      "actor_kind" => "user",
      "actor_id" => "spoofed-user",
      "actor_label" => "someone else"
    })

    [create] = history(id) |> by_action("create")
    assert create["actor_kind"] == "api_token"
    assert create["actor_id"] == token_id
    refute create["actor_label"] == "someone else"
  end

  test "CONTROL: a caller-less revision on the same row stays NULL, never an empty string",
       %{token_id: token_id} do
    id = uniq("rev-actor-control")
    create_and_publish!(id)

    {:ok, doc} = Content.get_document(id, "task", @dataset)

    # The pre-change shape: the 7-arity seam, no caller_context in opts.
    {:ok, _} =
      Broadcast.tap_broadcast({:ok, doc}, @dataset, "task", "update", doc.rev, :api, nil)

    revisions = history(id)
    [control] = by_action(revisions, "update")

    for key <- ~w(actor_kind actor_id actor_label actor_user_id) do
      assert Map.has_key?(control, key), "#{key} missing from the history row"
      assert control[key] == nil, "#{key} = #{inspect(control[key])} on a caller-less revision"
    end

    # ...and the read distinguishes the two on the SAME row.
    [stamped] = by_action(revisions, "create")
    assert stamped["actor_kind"] == "api_token"
    assert stamped["actor_id"] == token_id
  end
end
