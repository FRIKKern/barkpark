defmodule BarkparkWeb.Contract.ExportTest do
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Content

  # A conn adapter whose socket is already gone: `send_chunked` succeeds (the
  # 200 + headers were flushed before the client vanished) but every `chunk/2`
  # answers `{:error, :closed}` — exactly what Cowboy returns when the owner
  # kills `bp export` or the network drops mid-backup.
  defmodule ClosedSocketAdapter do
    def send_chunked(state, _status, _headers), do: {:ok, "", state}
    def chunk(_state, _body), do: {:error, :closed}
  end

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.create_document("post", %{"doc_id" => "drafts.e1", "title" => "One"}, "test")
    Content.create_document("post", %{"doc_id" => "drafts.e2", "title" => "Two"}, "test")
    Content.publish_document("e1", "post", "test")
    :ok
  end

  defp do_export(conn, dataset, params \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> get("/v1/data/export/#{dataset}", params)
  end

  # A conn the controller can run against directly, whose socket is already gone.
  defp closed_socket_conn do
    :get
    |> Phoenix.ConnTest.build_conn("/v1/data/export/test", %{})
    |> Map.put(:adapter, {ClosedSocketAdapter, nil})
    # BARE CONN — built directly, so no `:api` pipeline and no
    # AssignDefaultScope. These tests assert the HANGUP path (halt instead of
    # raise; an honest log line), not tenancy. The fixture rows are created
    # unscoped and land in the seeded Default, so stand in for what the pipeline
    # would have assigned — otherwise the sentinel
    # (task-3e2a70930c6df723) fires, the export streams zero rows, never reaches
    # the disconnect, and the log assertion measures nothing.
    |> Plug.Conn.assign(:current_workspace, Barkpark.Tenancy.get_default_workspace())
  end

  test "exports all documents as NDJSON", %{conn: conn} do
    resp = do_export(conn, "test")
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"

    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert length(docs) >= 2
    assert Enum.all?(docs, &Map.has_key?(&1, "_id"))
    assert Enum.all?(docs, &Map.has_key?(&1, "_type"))
  end

  test "filters export by type", %{conn: conn} do
    resp = do_export(conn, "test", %{"type" => "post"})
    assert resp.status == 200
    lines = resp.resp_body |> String.trim() |> String.split("\n")
    docs = Enum.map(lines, &Jason.decode!/1)
    assert Enum.all?(docs, &(&1["_type"] == "post"))
  end

  test "returns empty NDJSON for empty dataset", %{conn: conn} do
    resp = do_export(conn, "nonexistent")
    assert resp.status == 200
    assert resp.resp_body == ""
  end

  test "requires auth token", %{conn: conn} do
    resp = get(conn, "/v1/data/export/test")
    assert resp.status == 401
  end

  describe "Accept negotiation" do
    # The route rides `:scoped_api` under `plug :accepts ["json"]`, so a
    # spec-pure `Accept: application/x-ndjson` — the very type this controller
    # RESPONDS with, and the one `internal/apiclient/export.go` sends — used to
    # 406 in the pipeline BEFORE OptionalToken ever ran.
    test "the spec-pure `application/x-ndjson` Accept reaches the controller", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/x-ndjson")
        |> do_export("test")

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") |> hd() =~ "application/x-ndjson"
    end

    test "the Go client's `application/x-ndjson, application/json` Accept works", %{conn: conn} do
      resp =
        conn
        |> put_req_header("accept", "application/x-ndjson, application/json")
        |> do_export("test")

      assert resp.status == 200
    end
  end

  describe "client disconnect mid-export" do
    # The owner of a personal instance runs the backup unattended. A hangup used
    # to raise a MatchError on `{:ok, acc} = chunk(acc, line)` INSIDE the open
    # `Repo.transaction`, aborting while holding the streaming cursor's DB
    # connection and leaving a truncated file with no honest signal anywhere.
    test "a hangup halts the export instead of raising" do
      {out, _log} =
        with_log(fn ->
          BarkparkWeb.ExportController.export(closed_socket_conn(), %{"dataset" => "test"})
        end)

      assert %Plug.Conn{status: 200, state: :chunked} = out
    end

    test "the hangup is reported honestly in the log, naming the dataset and the cutoff" do
      log =
        capture_log(fn ->
          BarkparkWeb.ExportController.export(closed_socket_conn(), %{"dataset" => "test"})
        end)

      assert log =~ "export"
      assert log =~ "test"
      assert log =~ "closed"
      # The count of documents actually delivered — the honest "what I could
      # not do" the epic's law demands, since the 200 is already on the wire.
      assert log =~ "delivered=0"
    end
  end
end
