defmodule BarkparkCloud.Sites.BoxErrorEnvelope do
  @moduledoc """
  THE ONE reducer from a box refusal body to the `box_error*` wire fields —
  shared by `BarkparkCloud.Sites.BuildLog` and
  `BarkparkCloud.Sites.BuildLogBytes` so the two routes cannot drift.

  ## What went wrong (task-3468f99ad5a4e9b8, measured 2026-09-18)

  Both modules carried a byte-identical private clause:

      defp box_error(body) when is_map(body), do: Map.get(body, "error") || Map.get(body, "code")

  That is written for a box body whose `"error"` is a SLUG STRING
  (`build_log_unscrubbed`, `build_log_evicted`). The box's GENERIC 500 handler
  answers with the standard error ENVELOPE instead — `"error"` is a MAP of
  `code`/`hint`/`message`/`request_id` — so the clause passed a MAP out under a
  field every consumer types as a string:

      {"error":{"code":"internal_error","hint":"Retry shortly; …",
                "message":"unknown error (FunctionClauseError)",
                "request_id":"GNZOQHLsqlWoMDkAE8Vx"}}

  `encoding/json` hard-fails the whole record decode on that one field, so the
  operator running the supported verb saw a Go struct-field message instead of
  the box's own `request_id` — and nobody chased the box for 16 days.

  ## The contract

  `fields/1` ALWAYS returns the same three keys, and `:box_error` is ALWAYS a
  string or `nil` — never a map, and never a map STRINGIFIED. `inspect/1` or
  `to_string/1` on the envelope would satisfy "not a map" while handing the
  operator `"%{\\"code\\" => …}"`, which is neither the slug the field is typed
  as nor anything a client can branch on. So the envelope is REDUCED: its
  `code` becomes the slug, and the two facts that route an incident —
  `request_id` and `message` — reach the wire under keys of their OWN
  (`:box_error_request_id`, `:box_error_message`) rather than being dropped.

  A non-string, non-map `"error"` (a number, a list) reduces to `nil`: the field
  is typed as a string and this module is the place that keeps it one.
  """

  @max_message_bytes 4_000
  @truncation_marker " …[truncated]"

  @type t :: %{
          box_error: String.t() | nil,
          box_error_message: String.t() | nil,
          box_error_request_id: String.t() | nil
        }

  @doc """
  Reduce a box refusal body to the `box_error*` wire fields.

  The slug-string case passes through UNCHANGED (with both companion keys
  `nil`); the envelope case reduces to its `code` and carries `request_id` and
  `message` alongside.
  """
  @spec fields(term()) :: t()
  def fields(body) when is_map(body) do
    case Map.get(body, "error") do
      slug when is_binary(slug) ->
        wire(slug, nil, nil)

      envelope when is_map(envelope) ->
        wire(
          string(Map.get(envelope, "code")),
          string(Map.get(envelope, "message")),
          string(Map.get(envelope, "request_id"))
        )

      _ ->
        wire(string(Map.get(body, "code")), nil, nil)
    end
  end

  def fields(_body), do: wire(nil, nil, nil)

  defp wire(slug, message, request_id) do
    %{
      box_error: truncate(slug),
      box_error_message: truncate(message),
      box_error_request_id: truncate(request_id)
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp truncate(nil), do: nil

  defp truncate(text) when is_binary(text) do
    if byte_size(text) > @max_message_bytes do
      binary_part(text, 0, @max_message_bytes) <> @truncation_marker
    else
      text
    end
  end
end
