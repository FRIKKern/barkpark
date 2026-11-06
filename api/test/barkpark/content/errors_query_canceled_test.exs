defmodule Barkpark.Content.ErrorsQueryCanceledTest do
  @moduledoc """
  task-0f07d4c008199ba0, found in rehearsal #24192: a write statement that
  Postgres cancelled (SQLSTATE 57014, `:query_canceled`) answers the retryable
  503 `storage_unavailable`, not 500 `internal_error`. A `bp import` batch got
  the 500 after 16.8 s and the import stopped, because the import client
  shrinks and resends a batch only on 503 `storage_unavailable`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Content.Errors

  @user_cancel %Postgrex.Error{
    connection_id: 4242,
    postgres: %{
      code: :query_canceled,
      pg_code: "57014",
      severity: "ERROR",
      message: "canceling statement due to user request"
    }
  }

  defp envelope(term) do
    {env, _log} = with_log(fn -> Errors.to_envelope(term) end)
    env
  end

  test "a cancelled statement is 503 storage_unavailable with the connection_unavailable reason" do
    env = envelope({:error, @user_cancel})

    assert env.status == 503
    assert env.code == "storage_unavailable"
    assert env.reason == "connection_unavailable"
    assert env.hint =~ "CHECK WHETHER IT LANDED"
  end

  test "a cancelled statement inside a tagged tuple is the same 503" do
    env = envelope({:error, {:batch_failed, @user_cancel}})

    assert env.status == 503
    assert env.code == "storage_unavailable"
  end

  test "the message is fixed and never carries the exception text" do
    env = envelope({:error, @user_cancel})

    refute env.message =~ "user request"
    refute env.message =~ "57014"
    refute env.message =~ "4242"
    assert env.message =~ "cancelled a statement"
  end

  test "CONTROL: any other returned Postgrex.Error keeps the 500 catch-all" do
    other = %Postgrex.Error{
      postgres: %{code: :unique_violation, pg_code: "23505", severity: "ERROR"}
    }

    log =
      capture_log(fn ->
        env = Errors.to_envelope({:error, other})
        assert env.status == 500
        assert env.code == "internal_error"
      end)

    assert log =~ "no build/1 clause matched"
    refute Errors.query_canceled?(other)
  end

  test "query_canceled?/1 names only SQLSTATE 57014" do
    assert Errors.query_canceled?(@user_cancel)
    refute Errors.query_canceled?(%Postgrex.Error{message: "plain"})
    refute Errors.query_canceled?(DBConnection.ConnectionError.exception("tcp recv: closed"))
    refute Errors.query_canceled?(:query_canceled)
  end
end
