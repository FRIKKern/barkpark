defmodule Barkpark.Search.SearchRecoveryMemoTest do
  # A zero-hit search runs recovery passes. With the request memo on (an HTTP
  # request's scope opts carry `memoize: true`), those passes reuse the first
  # pass's dataset, schema and refresh-gate reads, and must still read only what
  # the caller may read.
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.WriteScope

  @ds "recovery-memo"
  @other "recovery-memo-other"

  setup do
    Barkpark.Search.SurfaceConfigs.seed_defaults!()

    for {name, visibility, ds} <- [
          {"post", "public", @ds},
          {"secret", "private", @ds},
          {"post", "public", @other}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => visibility,
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          ds
        )
    end

    for {type, id, title, ds} <- [
          {"post", "p-ada", "Ada Lovelace notes", @ds},
          {"secret", "s-ada", "Lovelace secret ledger", @ds},
          {"post", "o-ada", "Lovelace in another dataset", @other}
        ] do
      {:ok, _} =
        Content.create_document(type, %{"doc_id" => id, "content" => %{"title" => title}}, ds)

      {:ok, _} = Content.publish_document(id, type, ds)
    end

    WriteScope.reset_request_memo()
    on_exit(fn -> WriteScope.reset_request_memo() end)
    :ok
  end

  # The studio's call shape (match any), as an anonymous caller.
  defp search(q, memoize, match \\ :any) do
    WriteScope.reset_request_memo()

    Content.search_documents(q, @ds,
      types: ["post", "secret"],
      perspective: :drafts,
      limit: 200,
      match: match,
      memoize: memoize
    )
  end

  defp round_trips(fun) do
    me = self()
    id = "recovery-memo-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, _, _ ->
        if self() == me, do: send(me, :round_trip)
      end,
      nil
    )

    try do
      result = fun.()
      {result, count_round_trips(0)}
    after
      :telemetry.detach(id)
    end
  end

  defp count_round_trips(n) do
    receive do
      :round_trip -> count_round_trips(n + 1)
    after
      0 -> n
    end
  end

  test "a recovered search under the memo still returns only the caller's dataset and public types" do
    # Every word must match: none does, so the match_any recovery pass serves
    # "lovelace". The private type and the other dataset hold it too.
    {hits, total, meta} = search("lovelace zzzq", true, :all)

    assert meta.recovery == "match_any"
    assert total == 1
    assert Enum.map(hits, & &1.doc_id) == ["p-ada"]
    assert {hits, total, meta} == search("lovelace zzzq", false, :all)
  end

  test "the memo cuts a zero-hit search's round trips, and a new one goes red" do
    {_, without} = round_trips(fn -> search("lovelase", false) end)
    {_, with_memo} = round_trips(fn -> search("lovelase", true) end)

    # Measured 2026-10-25: 21 on main with or without the memo (the recovery
    # passes re-read the dataset, the public types and the refresh gates), 17
    # with it. A change that adds a round trip to this path goes red here.
    assert with_memo < without
    assert with_memo <= 17, "a zero-hit search took #{with_memo} round trips (was 17)"
  end
end
