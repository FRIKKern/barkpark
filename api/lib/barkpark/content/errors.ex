defmodule Barkpark.Content.Errors do
  @moduledoc "Maps internal error tuples to v1 JSON error envelopes."

  def to_envelope({:error, :not_found}),
    do: %{code: "not_found", message: "document not found", status: 404}

  def to_envelope({:error, :unauthorized}),
    do: %{code: "unauthorized", message: "missing or invalid token", status: 401}

  def to_envelope({:error, :forbidden}),
    do: %{code: "forbidden", message: "token lacks required permission", status: 403}

  def to_envelope({:error, :schema_unknown}),
    do: %{code: "schema_unknown", message: "no schema for type", status: 404}

  def to_envelope({:error, :rev_mismatch}),
    do: %{code: "rev_mismatch", message: "document was modified by another writer", status: 409}

  def to_envelope({:error, :malformed}),
    do: %{code: "malformed", message: "request body is malformed", status: 400}

  def to_envelope({:error, :conflict}),
    do: %{code: "conflict", message: "document already exists", status: 409}

  def to_envelope({:error, %Ecto.Changeset{} = cs}) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    %{code: "validation_failed", message: "document failed validation", status: 422, details: details}
  end

  def to_envelope({:error, :rate_limited}),
    do: %{code: "rate_limited", message: "rate limit exceeded", status: 429}

  def to_envelope({:error, reason}) when is_binary(reason),
    do: %{code: "internal_error", message: reason, status: 500}

  def to_envelope(_),
    do: %{code: "internal_error", message: "unknown error", status: 500}
end
