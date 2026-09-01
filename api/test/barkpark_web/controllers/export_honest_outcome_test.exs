defmodule BarkparkWeb.ExportHonestOutcomeTest do
  @moduledoc """
  The export verb's honest-outcome contract.

  `GET /v1/data/export/:dataset` commits its status the moment `send_chunked/2`
  runs, so a failure after that point can never be re-reported as a status code.
  Two rules follow, and this file pins both:

    1. Anything fallible that CAN be decided before the first byte MUST be —
       a wrong-shaped `?type` (`?type[]=post`, `?type[k]=v`) is a 400 with the
       connection still unchunked, not a 200 with an empty body.

    2. Anything that still fails mid-stream MUST be LOGGED and MARKED — the
       caller gets a terminating `_barkpark_export: "incomplete"` line and the
       operator gets a `Logger.warning` naming how far the export got. A
       truncated backup must never look complete.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "exphonest"
  @token "exphonest-token"

  setup do
    Auth.create_token(@token, "reader", @dataset, ["read"])

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [%{"name" => "body", "type" => "string"}]
      },
      @dataset
    )

    :ok
  end

  defp doc!(doc_id, body) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{"body" => body}},
        @dataset
      )

    doc
  end

  defp export(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
  end

  defp lines(body), do: String.split(body, "\n", trim: true)

  # ── 1. fallible-up-front: decide BEFORE the status is on the wire ───────────

  test "a list-shaped ?type is refused with a 400 before any chunk is sent" do
    doc!("drafts.p1", "one")

    conn = export("/v1/data/export/#{@dataset}?type[]=post")

    assert conn.status == 400
    refute conn.state == :chunked
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_filter"
  end

  test "a map-shaped ?type[k]=v is refused with a 400 before any chunk is sent" do
    doc!("drafts.p1", "one")

    conn = export("/v1/data/export/#{@dataset}?type[k]=post")

    assert conn.status == 400
    refute conn.state == :chunked
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_filter"
  end

  test "a well-formed ?type still filters the export" do
    doc!("drafts.p1", "one")

    conn = export("/v1/data/export/#{@dataset}?type=post")

    assert conn.status == 200
    assert [line] = lines(conn.resp_body)
    assert Jason.decode!(line)["_id"] == "drafts.p1"
  end

  # ── 2. positive control: a clean export is complete and says nothing ────────

  test "a clean export streams a complete 200 and emits no truncation warning" do
    doc!("drafts.p1", "one")
    doc!("drafts.p2", "two")

    {body, log} =
      with_log(fn ->
        conn = export("/v1/data/export/#{@dataset}")
        assert conn.status == 200
        conn.resp_body
      end)

    ids = Enum.map(lines(body), &Jason.decode!(&1)["_id"])
    assert Enum.sort(ids) == ["drafts.p1", "drafts.p2"]
    refute body =~ "_barkpark_export"
    refute log =~ "INCOMPLETE"
  end

  # ── 3. mid-stream raise: logged AND marked ─────────────────────────────────

  test "a mid-stream failure is logged and the stream is marked incomplete" do
    d1 = doc!("drafts.p1", "one")
    d2 = doc!("drafts.p2", "two")

    # Order the export deterministically (`order_by: asc inserted_at`) so the
    # good document is delivered FIRST and the poisoned one is met mid-stream.
    bump!(d1, -10)
    bump!(d2, 10)

    # Corrupt the second row's jsonb `content` into an ARRAY. Ecto's `:map` type
    # cannot load it, so `Repo.stream` raises while decoding that row — i.e.
    # AFTER the first document's line is already on the wire and long after
    # `send_chunked(200)` committed the status.
    poison!(d2)

    {body, log} =
      with_log(fn ->
        conn = export("/v1/data/export/#{@dataset}")
        assert conn.status == 200
        conn.resp_body
      end)

    # The operator is told, by the module's own honest-outcome wording.
    assert log =~ "export failed mid-stream"
    assert log =~ "INCOMPLETE"
    assert log =~ "delivered=1"

    # The caller is told, in-band: the last NDJSON line is an explicit marker,
    # so a restore cannot mistake a truncated dump for a complete one.
    marker = body |> lines() |> List.last() |> Jason.decode!()
    assert marker["_barkpark_export"] == "incomplete"
    assert marker["_delivered"] == 1
    refute Map.has_key?(marker, "_id")
  end

  @bump_sql "UPDATE documents SET inserted_at = $2 WHERE id = $1"
  @poison_sql "UPDATE documents SET content = '[]'::jsonb WHERE id = $1"

  defp bump!(doc, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), seconds, :second)
    Repo.query!(@bump_sql, [Ecto.UUID.dump!(doc.id), at])
  end

  defp poison!(doc) do
    Repo.query!(@poison_sql, [Ecto.UUID.dump!(doc.id)])
  end
end
