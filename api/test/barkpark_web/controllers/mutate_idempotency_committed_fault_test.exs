defmodule BarkparkWeb.MutateIdempotencyCommittedFaultTest do
  @moduledoc """
  A keyed mutate whose write COMMITTED and whose answer was still a fault
  (task-717c91a6e9b6758b): a raise after commit is a 500, a connection lost at
  commit is a 503. The plug used to release the key on any 5xx, so the client's
  resend under the same key and body ran the batch again and created a second
  row. The batch now marks the held key committed inside its own transaction,
  so the fault is remembered and replayed, and nothing runs twice. A fault
  BEFORE the write still releases the key, and the resend writes.

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.{Auth, Idempotency, Repo, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Repo.IdempotencyStore.Key

  @dataset "production"
  @token "barkpark-test-idem-committed-fault"

  setup do
    {:ok, token} =
      Auth.create_token(
        @token,
        "idem-committed-fault",
        "test",
        ["read", "write", "admin"],
        TenancyFixtures.default_workspace_id!()
      )

    on_exit(fn -> Application.delete_env(:barkpark, :writer_fault) end)
    %{token: token}
  end

  defp unique(prefix), do: "icf-#{prefix}-#{System.unique_integer([:positive])}"

  # A create with a server-assigned id: the shape a resend duplicates.
  defp create_body(title),
    do: Jason.encode!(%{"mutations" => [%{"create" => %{"_type" => "post", "title" => title}}]})

  defp post_keyed(key, body, extra \\ "") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
    |> post("/v1/data/mutate/#{@dataset}" <> extra, body)
  end

  defp rows_titled(title),
    do: Repo.aggregate(from(d in Document, where: d.title == ^title), :count)

  defp fault!(site, module, message),
    do: Application.put_env(:barkpark, :writer_fault, {site, module, message})

  defp clear_fault!, do: Application.delete_env(:barkpark, :writer_fault)

  defp key_state(token, key) do
    hash = Idempotency.hash_key(key, token.id, "POST", "/v1/data/mutate/#{@dataset}")
    Repo.one(from(k in Key, where: k.key_hash == ^hash, select: {k.state, k.status_code}))
  end

  describe "a write that committed and then answered a fault" do
    test "a raise after commit (500): the resend replays the 500 and writes no second row",
         %{token: token} do
      title = unique("after-commit-500")
      key = unique("k")
      fault!(:after_commit, RuntimeError, "boom after commit")

      {status, _headers, _body} =
        assert_error_sent(500, fn -> post_keyed(key, create_body(title)) end)

      assert status == 500
      assert rows_titled(title) == 1
      clear_fault!()

      resend = post_keyed(key, create_body(title))

      assert rows_titled(title) == 1, "the resend ran the batch again"
      assert resend.status == 500
      assert get_resp_header(resend, "idempotency-replay") == ["true"]
      assert key_state(token, key) == {"completed", 500}
    end

    test "a connection lost at commit (503): the resend replays the 503 and writes no second row" do
      title = unique("lost-at-commit")
      key = unique("k")
      fault!(:after_commit, DBConnection.ConnectionError, "connection lost at commit")

      first = ExUnit.CaptureLog.with_log(fn -> post_keyed(key, create_body(title)) end) |> elem(0)
      assert first.status == 503
      assert rows_titled(title) == 1
      clear_fault!()

      resend = post_keyed(key, create_body(title))

      assert rows_titled(title) == 1, "the resend ran the batch again"
      assert resend.status == 503
      assert get_resp_header(resend, "idempotency-replay") == ["true"]
    end
  end

  # The publish leg of `bp task create --publish` (#26844 review): a publish
  # that committed and then answered 500 used to run again on the resend, and
  # the second run found no draft (not_found), so the client discarded and
  # told the caller to re-file: a duplicate task.
  describe "a publish that committed and then answered a fault" do
    test "the resend replays the 500; it does not run the publish again into not_found" do
      id = unique("pub")
      draft = %{"mutations" => [%{"create" => %{"_id" => id, "_type" => "post", "title" => id}}]}
      assert post_keyed(unique("k"), Jason.encode!(draft)).status == 200

      key = unique("k")
      publish = Jason.encode!(%{"mutations" => [%{"publish" => %{"id" => id, "type" => "post"}}]})
      fault!(:after_commit, RuntimeError, "boom after publish")
      assert_error_sent(500, fn -> post_keyed(key, publish) end)
      clear_fault!()

      resend = post_keyed(key, publish)

      refute resend.resp_body =~ "not_found", "the resend ran the publish again"
      assert resend.status == 500
      assert get_resp_header(resend, "idempotency-replay") == ["true"]
      assert Repo.aggregate(from(d in Document, where: d.doc_id == ^id), :count) == 1
    end
  end

  describe "nothing committed" do
    test "a fault before the write (503) still releases the key, and the resend writes",
         %{token: token} do
      title = unique("before-write")
      key = unique("k")
      fault!(:batch_transaction, DBConnection.ConnectionError, "dropped from queue")

      first = ExUnit.CaptureLog.with_log(fn -> post_keyed(key, create_body(title)) end) |> elem(0)
      assert first.status == 503
      assert rows_titled(title) == 0
      assert key_state(token, key) == nil
      clear_fault!()

      resend = post_keyed(key, create_body(title))

      assert resend.status == 200
      assert get_resp_header(resend, "idempotency-replay") == []
      assert rows_titled(title) == 1
    end

    test "a dry run never marks the key", %{token: token} do
      attach_marks()
      key = unique("k")

      resp =
        post_keyed(key, Jason.encode!(%{"dryRun" => true, "mutations" => create_mutations()}))

      assert resp.status == 200
      refute_received {:marked, _}
      assert {"completed", 200} = key_state(token, key)
    end

    test "a batch refused on validation never marks the key" do
      attach_marks()
      key = unique("k")

      resp =
        post_keyed(key, Jason.encode!(%{"mutations" => [%{"create" => %{"title" => "no type"}}]}))

      assert resp.status in 400..499
      refute_received {:marked, _}
    end
  end

  describe "the held key belongs to one request" do
    test "a keyed request leaves no held key behind" do
      _ = post_keyed(unique("k"), create_body(unique("held")))
      assert Idempotency.held_key() == nil
    end

    # Bandit serves a keep-alive connection's requests in ONE process. A hash
    # left behind by a request that never reached before_send must not mark the
    # next request's transaction. ConnCase dispatches in the test process, so
    # this is that process serving a second request.
    test "a stale held key is not marked by the next, keyless request", %{token: token} do
      stale = Idempotency.hash_key(unique("stale"), token.id, "POST", "/v1/data/mutate/x")
      :claimed = Idempotency.claim(stale, "mutation:stale")
      Idempotency.hold(stale)

      resp =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{@token}")
        |> put_req_header("content-type", "application/json")
        |> post("/v1/data/mutate/#{@dataset}", create_body(unique("keyless")))

      assert resp.status == 200
      assert Repo.get(Key, stale).state == "pending", "the stale key was marked committed"
    end

    test "with no key held, mark_committed is a no-op" do
      Idempotency.forget_held_key()
      assert Idempotency.mark_committed() == :none
    end

    # The mark lives in the request process's dictionary. A write run in another
    # process (a Task, a GenServer call) does not see it, and falls back to
    # release-on-5xx.
    test "a write in another process does not see the held key", %{token: token} do
      hash = Idempotency.hash_key(unique("other-proc"), token.id, "POST", "/x")
      :claimed = Idempotency.claim(hash, "mutation:x")
      Idempotency.hold(hash)

      assert Task.async(fn -> Idempotency.mark_committed() end) |> Task.await() == :none
      assert Repo.get(Key, hash).state == "pending"
      Idempotency.forget_held_key()
    end
  end

  defp create_mutations, do: [%{"create" => %{"_type" => "post", "title" => unique("dry")}}]

  defp attach_marks do
    id = "icf-marks-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach(
      id,
      [:barkpark, :idempotency, :marked_committed],
      fn _event, _measure, meta, _ -> send(me, {:marked, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
