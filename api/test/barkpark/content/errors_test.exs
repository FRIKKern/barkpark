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

    assert Errors.to_envelope({:error, :not_found}) ==
             %{code: "not_found", message: "document not found", status: 404}
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
end
