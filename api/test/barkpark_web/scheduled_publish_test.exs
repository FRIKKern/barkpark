defmodule BarkparkWeb.ScheduledPublishTest do
  @moduledoc """
  Scheduled publish of a draft (task-8e88b5539acafdae). Owner decision
  2026-10-10: the publish runs AS the person who scheduled it, their identity
  goes into history, and it is refused if they lost write access by then.
  """
  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Ecto.Query

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Content.{CallerContext, MutationEvent, Revision, ScheduledPublishes}
  alias Barkpark.Content.Workers.ScheduledPublishWorker
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"
  @type_name "notice"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Notice",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    %{ws_id: TenancyFixtures.default_workspace_id!()}
  end

  defp token!(ws_id, perms \\ ["read", "write"]) do
    raw = "sched-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "sched", @dataset, perms, ws_id)
    {raw, token}
  end

  defp new_draft! do
    id = "sched-doc-#{System.unique_integer([:positive])}"

    {:ok, draft} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "D"}, @dataset)

    {id, draft}
  end

  defp future(seconds \\ 3600),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()

  defp authed(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp schedule(raw, body),
    do: raw |> authed() |> post("/v1/data/schedules/#{@dataset}", Jason.encode!(body))

  defp published?(id), do: match?({:ok, _}, Content.get_document(id, @type_name, @dataset))

  defp events(id, kind) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^"drafts.#{id}" and e.mutation == ^kind,
        select: e.id
    )
  end

  test "schedule, list, then the job publishes AS the scheduler", %{ws_id: ws_id} do
    {raw, token} = token!(ws_id)
    {id, _} = new_draft!()

    body =
      schedule(raw, %{"id" => id, "type" => @type_name, "publishAt" => future()})
      |> json_response(201)

    sched = body["schedule"]
    assert sched["status"] == "scheduled"
    assert sched["documentId"] == id
    assert sched["scheduledBy"]["kind"] == "api_token"
    assert sched["scheduledBy"]["id"] == token.id
    assert_enqueued(worker: ScheduledPublishWorker, args: %{id: sched["_id"]})
    assert [_] = events(id, "schedule")

    listed =
      raw |> authed() |> get("/v1/data/schedules/#{@dataset}?id=#{id}") |> json_response(200)

    assert [%{"_id" => listed_id}] = listed["result"]["schedules"]
    assert listed_id == sched["_id"]
    refute published?(id)

    assert :ok = perform_job(ScheduledPublishWorker, %{"id" => sched["_id"]})

    assert published?(id)
    assert {:ok, %{status: "published"}} = fetch(sched["_id"])

    # History names the scheduler, not a system user.
    rev =
      Repo.one(
        from r in Revision,
          where: r.doc_id == ^id and r.action == "publish",
          order_by: [desc: r.inserted_at],
          limit: 1
      )

    assert rev.actor_kind == "api_token"
    assert rev.actor_id == token.id
  end

  test "a user scheduler is named in history", %{ws_id: ws_id} do
    user =
      Barkpark.AccountsFixtures.register_user(
        "sched-#{System.unique_integer([:positive])}@example.com"
      )

    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, "member", "user")
    {id, _} = new_draft!()

    {:ok, row} =
      ScheduledPublishes.schedule(@type_name, id, @dataset, future(),
        caller_context: CallerContext.from_user(user.id, load_grants: false),
        workspace_id: ws_id
      )

    assert {:ok, %{status: "published"}} = ScheduledPublishes.run(row.id)
    assert published?(id)

    rev =
      Repo.one(
        from r in Revision,
          where: r.doc_id == ^id and r.action == "publish",
          order_by: [desc: r.inserted_at],
          limit: 1
      )

    assert rev.actor_kind == "user"
    assert rev.actor_id == user.id
    assert rev.actor_user_id == user.id
  end

  describe "refused when the scheduler lost write access by then" do
    test "a user removed from the workspace", %{ws_id: ws_id} do
      user =
        Barkpark.AccountsFixtures.register_user(
          "sched-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, seat} = TenancyAuth.create_membership(ws_id, user.id, "member", "user")
      {id, _} = new_draft!()

      {:ok, row} =
        ScheduledPublishes.schedule(@type_name, id, @dataset, future(),
          caller_context: CallerContext.from_user(user.id, load_grants: false),
          workspace_id: ws_id
        )

      Repo.delete!(seat)

      assert {:ok, %{status: "refused", reason: reason}} = ScheduledPublishes.run(row.id)
      assert reason =~ "no longer has write access"
      refute published?(id)
      assert [_] = events(id, "unschedule")
    end

    test "a token whose seat lost write (control: same token publishes while seated)",
         %{ws_id: ws_id} do
      {_raw, token} = token!(ws_id)
      {id, _} = new_draft!()
      ctx = CallerContext.from_token(token, workspace_id: ws_id)

      {:ok, row} =
        ScheduledPublishes.schedule(@type_name, id, @dataset, future(),
          caller_context: ctx,
          workspace_id: ws_id
        )

      Membership
      |> Repo.get_by!(principal_id: token.id, principal_type: "api_token", workspace_id: ws_id)
      |> Repo.delete!()

      assert {:ok, %{status: "refused"}} = ScheduledPublishes.run(row.id)
      refute published?(id)

      # Control: the same shape publishes while the seat exists.
      {_raw2, token2} = token!(ws_id)
      {id2, _} = new_draft!()

      {:ok, row2} =
        ScheduledPublishes.schedule(@type_name, id2, @dataset, future(),
          caller_context: CallerContext.from_token(token2, workspace_id: ws_id),
          workspace_id: ws_id
        )

      assert {:ok, %{status: "published"}} = ScheduledPublishes.run(row2.id)
      assert published?(id2)
    end

    test "a revoked token", %{ws_id: ws_id} do
      {_raw, token} = token!(ws_id)
      {id, _} = new_draft!()

      {:ok, row} =
        ScheduledPublishes.schedule(@type_name, id, @dataset, future(),
          caller_context: CallerContext.from_token(token, workspace_id: ws_id),
          workspace_id: ws_id
        )

      {:ok, _} = Auth.revoke_token(token)

      assert {:ok, %{status: "refused", reason: reason}} = ScheduledPublishes.run(row.id)
      assert reason =~ "revoked or expired"
      refute published?(id)
    end
  end

  test "cancel: the schedule ends, the job does nothing, the draft stays", %{ws_id: ws_id} do
    {raw, _} = token!(ws_id)
    {id, _} = new_draft!()

    sched =
      schedule(raw, %{"id" => id, "type" => @type_name, "publishAt" => future()})
      |> json_response(201)
      |> Map.fetch!("schedule")

    cancelled =
      raw
      |> authed()
      |> delete("/v1/data/schedules/#{@dataset}/#{sched["_id"]}")
      |> json_response(200)

    assert cancelled["schedule"]["status"] == "cancelled"
    assert [_] = events(id, "unschedule")

    assert :ok = perform_job(ScheduledPublishWorker, %{"id" => sched["_id"]})
    refute published?(id)

    # A second cancel is a conflict, not a silent success.
    assert raw
           |> authed()
           |> delete("/v1/data/schedules/#{@dataset}/#{sched["_id"]}")
           |> json_response(409)
  end

  test "a pinned rev that moved fails the schedule and leaves the draft", %{ws_id: ws_id} do
    {raw, _} = token!(ws_id)
    {id, draft} = new_draft!()

    sched =
      schedule(raw, %{
        "id" => id,
        "type" => @type_name,
        "publishAt" => future(),
        "ifRevisionID" => draft.rev
      })
      |> json_response(201)
      |> Map.fetch!("schedule")

    {:ok, _} =
      Content.upsert_document(@type_name, %{"doc_id" => id, "title" => "Edited"}, @dataset)

    assert {:ok, %{status: "failed", reason: reason}} = ScheduledPublishes.run(sched["_id"])
    assert reason =~ "draft changed"
    refute published?(id)
  end

  describe "refusals at schedule time" do
    test "a past publishAt is 422", %{ws_id: ws_id} do
      {raw, _} = token!(ws_id)
      {id, _} = new_draft!()

      body =
        schedule(raw, %{"id" => id, "type" => @type_name, "publishAt" => future(-60)})
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
    end

    test "a second pending schedule for the same document is 409", %{ws_id: ws_id} do
      {raw, _} = token!(ws_id)
      {id, _} = new_draft!()
      body = %{"id" => id, "type" => @type_name, "publishAt" => future()}

      assert schedule(raw, body) |> json_response(201)
      assert schedule(raw, body) |> json_response(409)
    end

    test "no draft is 404", %{ws_id: ws_id} do
      {raw, _} = token!(ws_id)

      assert schedule(raw, %{
               "id" => "nope-#{System.unique_integer()}",
               "type" => @type_name,
               "publishAt" => future()
             })
             |> json_response(404)
    end

    test "a read-only token cannot schedule or cancel", %{ws_id: ws_id} do
      {raw, _} = token!(ws_id, ["read"])
      {id, _} = new_draft!()

      assert schedule(raw, %{"id" => id, "type" => @type_name, "publishAt" => future()})
             |> json_response(403)

      assert raw
             |> authed()
             |> delete("/v1/data/schedules/#{@dataset}/#{Ecto.UUID.generate()}")
             |> json_response(403)
    end
  end

  defp fetch(id) do
    case Repo.get(Barkpark.Content.ScheduledPublish, id) do
      nil -> :error
      row -> {:ok, row}
    end
  end
end
