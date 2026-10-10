defmodule BarkparkWeb.MutateStaleRowRetryTest do
  @moduledoc """
  task-f25c61a3a3c2cb9d — a createOrReplace that loses its row to a concurrent
  writer (a publish of the same id moves the draft between the read and the
  update) raised Ecto.StaleEntryError, and the caller got 409 `internal_error`
  "unknown error (Ecto.StaleEntryError)" — 43 of 100 in a real two-process
  race. The batch now runs once more and lands (last write wins); a second
  loss answers a typed `rev_mismatch`, never `internal_error`.

  The race is made deterministic with a `before_save` hook that removes the
  draft row inside the window, exactly what the racing publish does.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Content.Document

  defmodule StaleInterleave do
    @moduledoc false
    def lifecycle_hooks, do: %{before_save: [&__MODULE__.run/1]}

    def run(%{doc: doc}) do
      case Process.get(:stale_interleave) do
        n when is_integer(n) and n > 0 ->
          Process.put(:stale_interleave, n - 1)
          id = Map.get(doc, "doc_id") || Map.get(doc, :doc_id)
          Repo.delete_all(from(d in Document, where: d.doc_id == ^id))

        _ ->
          :ok
      end

      :ok
    end

    def run(_), do: :ok
  end

  @ds "stale-retry-test"

  setup do
    token = "stale-retry-#{System.unique_integer([:positive])}"

    Auth.create_token(
      token,
      "dev",
      @ds,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    previous = Barkpark.PluginEnv.capture()

    Barkpark.PluginEnv.put!(
      Enum.map(Barkpark.Plugins.Registry.all(), & &1.module) ++ [StaleInterleave]
    )

    on_exit(fn -> Barkpark.PluginEnv.restore(previous) end)

    %{token: token}
  end

  defp mutate(token, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@ds}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp create_or_replace(token, id, title),
    do:
      mutate(token, [%{"createOrReplace" => %{"_id" => id, "_type" => "post", "title" => title}}])

  test "the row moved once: the batch retries and the write lands, last write wins", %{token: t} do
    id = "stale-#{System.unique_integer([:positive])}"
    assert create_or_replace(t, id, "v0").status == 200

    Process.put(:stale_interleave, 1)
    resp = create_or_replace(t, id, "v1")

    assert resp.status == 200, resp.resp_body
    refute resp.resp_body =~ "internal_error"

    titles = Repo.all(from(d in Document, where: d.doc_id == ^"drafts.#{id}", select: d.title))
    assert titles == ["v1"]
  end

  test "the row moved twice: a typed rev_mismatch 409, never internal_error", %{token: t} do
    id = "stale-#{System.unique_integer([:positive])}"
    assert create_or_replace(t, id, "v0").status == 200

    Process.put(:stale_interleave, 2)
    resp = create_or_replace(t, id, "v1")

    assert resp.status == 409, resp.resp_body
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "rev_mismatch"
    refute resp.resp_body =~ "StaleEntryError"
  end
end
