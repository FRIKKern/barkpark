defmodule Barkpark.Content.ErrorsTest do
  use ExUnit.Case, async: false
  alias Barkpark.Content.Errors

  setup do
    prev = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(prev) end)
    :ok
  end

  test "maps not_found" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, :not_found})
    assert env.code == "not_found"
    assert env.message == "document not found"
    assert env.status == 404
    # hint is additive — code/message/status stay stable
    assert is_binary(env.hint) and env.hint != ""
    refute Map.has_key?(env, :request_id)
  end

  test "registers a fix-suggesting hint for known codes without mutating code/message/status" do
    Logger.metadata(request_id: nil)

    for {reason, code} <- [
          {{:error, :not_found}, "not_found"},
          {{:error, :unauthorized}, "unauthorized"},
          {{:error, :rate_limited}, "rate_limited"}
        ] do
      env = Errors.to_envelope(reason)
      assert env.code == code
      assert is_binary(env.hint) and env.hint != ""
    end
  end

  test "validation_failed changeset envelope carries a hint" do
    Logger.metadata(request_id: nil)

    cs =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert is_binary(env.hint) and env.hint != ""
  end

  test "binary-reason (internal_error) envelope still works and carries its hint" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, "boom"})
    assert env.code == "internal_error"
    assert env.message == "boom"
    assert env.status == 500
    assert is_binary(env.hint) and env.hint != ""
  end

  test "catch-all unknown reason maps to internal_error with a hint" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope(:totally_unexpected)
    assert env.code == "internal_error"
    assert env.message == "unknown error"
    assert env.status == 500
    assert is_binary(env.hint) and env.hint != ""
  end

  test "maps changeset errors" do
    Logger.metadata(request_id: nil)

    cs =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == %{title: ["can't be blank"]}
    refute Map.has_key?(env, :request_id)
  end

  test "maps rev mismatch" do
    Logger.metadata(request_id: nil)
    assert %{code: "rev_mismatch", status: 409} = Errors.to_envelope({:error, :rev_mismatch})
  end

  test "maps invalid_task_content to a 422 with the field errors" do
    Logger.metadata(request_id: nil)

    # Regression: a task create missing kind/lifecycle_status fell through to
    # the catch-all and surfaced as a 500 "unknown error" — a validation
    # failure with no signal about what to fix.
    errors = %{"kind" => ["is required"]}
    env = Errors.to_envelope({:error, {:invalid_task_content, errors}})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == errors
  end

  test "to_envelope/2 with nil conn omits request_id when Logger metadata empty" do
    Logger.metadata(request_id: nil)
    env = Errors.to_envelope({:error, :not_found}, nil)
    refute Map.has_key?(env, :request_id)
  end

  test "to_envelope/2 pulls request_id from Logger metadata" do
    Logger.metadata(request_id: "test-req-123")
    conn = %Plug.Conn{}
    env = Errors.to_envelope({:error, :not_found}, conn)
    assert env.request_id == "test-req-123"
    assert env.code == "not_found"
    assert env.status == 404
  end

  test "to_envelope/2 falls back to x-request-id resp header when Logger metadata missing" do
    Logger.metadata(request_id: nil)
    conn = Plug.Conn.put_resp_header(%Plug.Conn{}, "x-request-id", "header-req-456")
    env = Errors.to_envelope({:error, :unauthorized}, conn)
    assert env.request_id == "header-req-456"
  end

  test "to_envelope/1 still works and omits request_id when metadata empty" do
    Logger.metadata(request_id: nil)
    env = Errors.to_envelope({:error, :forbidden})
    refute Map.has_key?(env, :request_id)
  end

  # A plugin lifecycle veto ({:halt, reason} → {:error, {:halted, reason}}) must
  # reach the bp CLI + SDK as the CANONICAL envelope — code "halted", 409, the
  # reason verbatim as the message, plus the additive hint. MutateController used
  # to emit a bare %{error: "halted", reason: reason} with no code/request_id;
  # this is the spine that makes the reroute conform. (Reverting the build/1
  # clause drops this to the binary/catch-all path → internal_error/500.)
  test "maps a plugin halt {:halted, reason} to a 409 with code \"halted\"" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:halted, "tenant is over quota"}})
    assert env.code == "halted"
    assert env.status == 409
    assert env.message == "tenant is over quota"
    # additive hint, like every other registered code
    assert is_binary(env.hint) and env.hint != ""
  end

  test "a non-binary halt reason still yields a non-empty halted message" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:halted, {:policy, :blocked}}})
    assert env.code == "halted"
    assert env.status == 409
    assert is_binary(env.message) and env.message != ""
  end
end
