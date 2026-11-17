defmodule BarkparkWeb.MutateIdempotencyKeyBoundTest do
  @moduledoc """
  `POST /v1/data/mutate/:dataset` (flat and scoped) binds its `Idempotency-Key`
  to the request (task-c65741be368a3f14).

  The key used to hash only token, method and path. A client that reused one
  key for a different `mutations` array got the first answer replayed
  (`Idempotency-Replay: true`, 200) and believed its second mutation ran;
  nothing was written. Now:

    * the same key with a different body or query string is refused 422
      `idempotency_key_reused`, and the second body is not written;
    * an exact retry still replays the first answer byte-for-byte, and the
      key order a client happens to serialize does not count as a difference;
    * a key stored before the binding (bare scope `"mutation"`, at most 24 h
      old at deploy) is still honoured: its retry replays the stored answer,
      and a retry while it is pending gets 409, not 422.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Idempotency, TenancyFixtures}

  @token "barkpark-test-mutate-idem-bound"
  @dataset "production"

  setup do
    {:ok, token} =
      Auth.create_token(
        @token,
        "test-mutate-idem-bound",
        "test",
        ["read", "write", "admin"],
        TenancyFixtures.default_workspace_id!()
      )

    {ws, project} = TenancyFixtures.ensure_default_scope!()

    %{
      token: token,
      urls: [
        "/v1/data/mutate/#{@dataset}",
        "/w/#{ws.slug}/p/#{project.slug}/v1/data/mutate/#{@dataset}"
      ]
    }
  end

  test "the same key with a different mutations body is 422 idempotency_key_reused, and nothing is written",
       %{urls: urls} do
    for url <- urls do
      key = unique("reused")
      first_id = unique("first")
      second_id = unique("second")

      first = post(conn_with(key), url, create_body(first_id))
      assert first.status == 200, "#{url}: first #{first.status} #{first.resp_body}"
      assert written?(first_id)

      second = post(conn_with(key), url, create_body(second_id))

      replayed = get_resp_header(second, "idempotency-replay")

      assert replayed == [],
             "#{url}: the first answer was replayed for a different body (status #{second.status})"

      assert second.status == 422, "#{url}: #{second.status} #{second.resp_body}"
      assert Jason.decode!(second.resp_body)["error"]["code"] == "idempotency_key_reused"
      refute written?(second_id), "#{url}: the second body was written"
    end
  end

  test "the same key with a different query string is 422 idempotency_key_reused",
       %{urls: urls} do
    for url <- urls do
      key = unique("query")
      body = create_body(unique("query-doc"))

      first = post(conn_with(key), url, body)
      assert first.status == 200, "#{url}: first #{first.status} #{first.resp_body}"

      second = post(conn_with(key), url <> "?returnDocuments=true", body)
      assert second.status == 422, "#{url}: #{second.status} #{second.resp_body}"
      assert Jason.decode!(second.resp_body)["error"]["code"] == "idempotency_key_reused"
    end
  end

  test "an exact retry still replays the first answer byte-for-byte, whatever the key order",
       %{urls: urls} do
    for url <- urls do
      key = unique("retry")
      id = unique("retry-doc")

      first = post(conn_with(key), url, create_body(id))
      assert first.status == 200, "#{url}: first #{first.status} #{first.resp_body}"

      again = post(conn_with(key), url, create_body(id))
      assert get_resp_header(again, "idempotency-replay") == ["true"]
      assert again.status == 200
      assert again.resp_body == first.resp_body

      # The same mutation serialized with its keys in another order.
      reordered =
        ~s({"mutations":[{"create":{"title":"#{id}","_id":"#{id}","_type":"post"}}]})

      third = post(conn_with(key), url, reordered)
      assert get_resp_header(third, "idempotency-replay") == ["true"]
      assert third.resp_body == first.resp_body
    end
  end

  describe "a key stored before the binding (bare scope \"mutation\")" do
    # What the unbound plug stored: scope "mutation", hash over the raw path.
    defp pre_binding_row!(token, key, url, state) do
      hash = Idempotency.hash_key(key, token.id, "POST", url)
      :claimed = Idempotency.claim(hash, "mutation")

      if state == :completed,
        do: Idempotency.complete(hash, "mutation", 200, ~s({"transactionId":"pre-deploy"}), [])

      hash
    end

    test "its retry after the deploy replays the stored answer, not 422", %{token: token} do
      url = "/v1/data/mutate/#{@dataset}"
      key = unique("pre-completed")
      id = unique("pre-doc")
      pre_binding_row!(token, key, url, :completed)

      retry = post(conn_with(key), url, create_body(id))

      assert retry.status == 200, "#{retry.status} #{retry.resp_body}"
      assert get_resp_header(retry, "idempotency-replay") == ["true"]
      assert retry.resp_body == ~s({"transactionId":"pre-deploy"})
      refute written?(id), "the handler ran a second time"
    end

    test "a retry while it is still pending is 409 idempotency_key_in_use, not 422",
         %{token: token} do
      url = "/v1/data/mutate/#{@dataset}"
      key = unique("pre-pending")
      pre_binding_row!(token, key, url, :pending)

      retry = post(conn_with(key), url, create_body(unique("pre-doc")))

      assert retry.status == 409, "#{retry.status} #{retry.resp_body}"
      assert Jason.decode!(retry.resp_body)["error"]["code"] == "idempotency_key_in_use"
    end

    test "it is honoured only by a bound mutate scope, never by another mount's scope" do
      hash = Idempotency.hash_key(unique("pre-other"), Ecto.UUID.generate(), "POST", "/x")
      :claimed = Idempotency.claim(hash, "mutation")
      Idempotency.complete(hash, "mutation", 200, "{}", [])

      assert Idempotency.claim(hash, "chat_send:" <> String.duplicate("0", 64)) == :mismatch
      assert {:replay, _} = Idempotency.claim(hash, "mutation:" <> String.duplicate("0", 64))
    end
  end

  defp create_body(id),
    do:
      Jason.encode!(%{
        "mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => id}}]
      })

  defp written?(id) do
    Enum.any?(
      ["drafts." <> id, id],
      &match?({:ok, _}, Content.get_document(&1, "post", @dataset))
    )
  end

  defp unique(prefix), do: "mik-#{prefix}-#{System.unique_integer([:positive])}"

  defp conn_with(key) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
  end
end
