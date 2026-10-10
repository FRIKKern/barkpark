defmodule BarkparkWeb.ScheduleController do
  @moduledoc """
  Scheduled publishes of a document's draft (task-8e88b5539acafdae).

    * `POST   /v1/data/schedules/:dataset` — `{"id", "type", "publishAt",
      "ifRevisionID"?}` schedules the draft. `ifRevisionID` pins the draft rev.
    * `GET    /v1/data/schedules/:dataset` — `?id=&type=&status=` lists them
      (default: pending only; `status=all` for every status) as
      `{"result": {"schedules": [...]}}`.
    * `DELETE /v1/data/schedules/:dataset/:schedule_id` — cancels a pending one.

  Writes ride the same `:require_write` gate as mutate; the publish itself
  runs later AS the scheduler (see `Barkpark.Content.ScheduledPublishes`).
  """
  use BarkparkWeb, :controller
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.{Errors, ScheduledPublish, ScheduledPublishes}
  alias BarkparkWeb.ErrorResponse

  def create(conn, %{"dataset" => dataset} = params) do
    opts = scope_opts(conn) |> put_pin(params["ifRevisionID"])

    case ScheduledPublishes.schedule(
           params["type"],
           params["id"],
           dataset,
           params["publishAt"],
           opts
         ) do
      {:ok, row} ->
        conn |> put_status(201) |> json(%{schedule: schedule_json(row)})

      error ->
        respond_with_error(conn, error)
    end
  end

  def index(conn, %{"dataset" => dataset} = params) do
    rows =
      ScheduledPublishes.list(
        dataset,
        Map.take(params, ["id", "type", "status"]),
        scope_opts(conn)
      )

    json(conn, %{result: %{schedules: Enum.map(rows, &schedule_json/1)}})
  end

  def delete(conn, %{"dataset" => dataset, "schedule_id" => id}) do
    case ScheduledPublishes.cancel(id, dataset, scope_opts(conn)) do
      {:ok, row} -> json(conn, %{schedule: schedule_json(row)})
      error -> respond_with_error(conn, error)
    end
  end

  defp put_pin(opts, rev) when is_binary(rev) and rev != "",
    do: Keyword.put(opts, :draft_rev, rev)

  defp put_pin(opts, _rev), do: opts

  defp schedule_json(%ScheduledPublish{} = row) do
    %{
      _id: row.id,
      documentId: row.doc_id,
      type: row.type,
      dataset: row.dataset,
      publishAt: row.publish_at,
      ifRevisionID: row.draft_rev,
      status: row.status,
      reason: row.reason,
      scheduledBy: %{kind: row.principal_type, id: row.principal_id, userId: row.acting_user_id},
      createdAt: row.inserted_at,
      completedAt: row.completed_at
    }
  end

  defp respond_with_error(conn, {:error, {:schedule_invalid, message}}),
    do: ErrorResponse.emit_custom(conn, 422, "validation_failed", message, %{field: "publishAt"})

  defp respond_with_error(conn, {:error, :schedule_exists}),
    do:
      ErrorResponse.emit_custom(
        conn,
        409,
        "conflict",
        "this document already has a pending scheduled publish",
        %{},
        "List it with GET /v1/data/schedules/:dataset?id=<id>, cancel it, then schedule again."
      )

  defp respond_with_error(conn, {:error, {:schedule_not_pending, status}}),
    do:
      ErrorResponse.emit_custom(
        conn,
        409,
        "conflict",
        "this schedule is #{status}, not pending",
        %{status: status}
      )

  defp respond_with_error(conn, {:error, _} = error) do
    env = Errors.to_envelope(error, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
