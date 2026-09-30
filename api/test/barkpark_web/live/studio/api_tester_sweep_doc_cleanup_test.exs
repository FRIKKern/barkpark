defmodule BarkparkWeb.Studio.ApiTesterSweepDocCleanupTest do
  @moduledoc """
  Run all must not leave fixture documents in the author's real dataset.

  Stranger walk (2026-09-30): every Run all left "From the playground" (a fresh
  id each run, so they piled up), "Upserted", "Create once", "Revised title",
  "Publish me" and "Unpublish me" in the Post list. The sweep now deletes the
  ids its own mutate scenarios touched — read from the REQUEST it sent.
  """
  use ExUnit.Case, async: true

  alias Barkpark.ApiTester.Endpoints
  alias Barkpark.ApiTester.Endpoints.Mutate
  alias BarkparkWeb.Studio.ApiTesterLive

  @path "/v1/data/mutate/production"

  defp spec(id), do: Enum.find(Endpoints.all("production"), &(&1.id == id))

  defp deleted_ids(steps) do
    Enum.map(steps, fn %{body: %{"mutations" => [%{"delete" => %{"id" => id}}]}} -> id end)
  end

  test "every mutate scenario's fixture ids are collected, published-coalesced, each deleted twice" do
    for id <-
          ~w(mutate-create mutate-createOrReplace mutate-createIfNotExists mutate-patch mutate-publish mutate-unpublish mutate-discardDraft) do
      body = spec(id).body_example
      steps = Mutate.touched_documents_cleanup(body, @path)

      assert steps != [], "#{id} must clean up the documents it touches"

      for s <- steps do
        assert s.path == @path and s.method == :post
      end

      ids = deleted_ids(steps)
      assert Enum.all?(ids, &String.starts_with?(&1, "playground-")), "#{id}: #{inspect(ids)}"
      refute Enum.any?(ids, &String.starts_with?(&1, "drafts.")), "ids are published-coalesced"
      assert Enum.frequencies(ids) |> Map.values() |> Enum.all?(&(&1 == 2))
    end
  end

  test "a body with no mutations cleans nothing" do
    assert Mutate.touched_documents_cleanup(nil, @path) == []
    assert Mutate.touched_documents_cleanup(%{"x" => 1}, @path) == []
  end

  test "sweep_cleanup posts the deletes to the scenario's own path after a 2xx, and not after a refusal" do
    bypass = Bypass.open()
    parent = self()

    Bypass.expect(bypass, "POST", @path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:cleanup, Jason.decode!(raw)})
      Plug.Conn.resp(conn, 200, ~s({"results":[]}))
    end)

    ep = spec("mutate-createOrReplace")
    request = %{path: @path, body: ep.body_example}
    config = %{token: "tok", base: "http://localhost:#{bypass.port}"}

    out =
      ApiTesterLive.sweep_cleanup(
        %{verdict: :pass, status: 200, body_json: %{"results" => []}},
        ep,
        config,
        request
      )

    assert [%{status: 200}, %{status: 200}] = out.sweep_cleanup

    assert_receive {:cleanup,
                    %{
                      "mutations" => [
                        %{"delete" => %{"id" => "playground-upsert-1", "type" => "post"}}
                      ]
                    }}

    refused = %{verdict: :pass, status: 401, body_json: %{"error" => %{"code" => "unauthorized"}}}
    assert ApiTesterLive.sweep_cleanup(refused, ep, config, request) == refused
  end
end
