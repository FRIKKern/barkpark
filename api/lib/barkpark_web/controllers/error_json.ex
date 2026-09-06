defmodule BarkparkWeb.ErrorJSON do
  @moduledoc """
  Renders errors on JSON requests (wired in `config/config.exs` `render_errors`).

  Phoenix's RenderErrors layer reaches here as the LAST line of defence — when a
  request RAISES, exits, or hits an unmatched route after `action_fallback` no
  longer applies. Without a working module here the error renderer itself
  crashes ("the module does not exist") and the client gets a dropped connection
  instead of a response.

  It emits the SAME canonical v1 envelope as `BarkparkWeb.FallbackController`,
  built by `Barkpark.Content.Errors` (the one owner of the error vocabulary), so
  a crash-path 500 is byte-identical to a controller-emitted one and every
  SDK/CLI consumer can still key on `error.code`.

  Shape (`Barkpark.Content.Errors` → `FallbackController` wrapping):

      %{error: %{code: ..., message: ..., hint: ..., request_id: ...}}

  * `500.json` (and any other unhandled fault) → `internal_error`, message is the
    generic builder text plus the FAULT FAMILY in parentheses — the exception
    module name, or an allowlisted exit head atom. NO exception *message*,
    inspected reason, or stack detail is ever leaked.
  * `404.json` → `not_found`.
  * catch-all clause handles any `<status>.json` template name.

  ## Why the family, and why the code never moves

  Every crash-path 500 used to read `"unknown error"`, so an operator reading a
  deploy log could not tell a pool blip from a code defect. The family is the
  smallest disclosure that separates them (`DBConnection.ConnectionError` vs
  `FunctionClauseError`) while leaking nothing caller-supplied.

  The `code` stays byte-identical `"internal_error"`: the cloud deploy poller
  (`BarkparkCloud.Sites.Deploy.transient_refusal?/1`) grants its retry grace by
  matching the CODE, never the message. Moving the code — even to a "better"
  one — turns that grace terminal. Only the message changes here.
  """

  alias Barkpark.Content.Errors

  # Phoenix hands "<status>.json" (e.g. "404.json", "500.json"). 404 maps to the
  # canonical `not_found`; every other status (500, and the rare raised
  # Plug.Exception RenderErrors surfaces) collapses to the generic
  # `internal_error` — the HTTP status stays whatever the exception set, but the
  # body never leaks internals. This single clause is the template_name catch-all.
  def render(template, assigns) do
    conn = Map.get(assigns, :conn)

    env =
      template
      |> reason_for_template(assigns)
      |> Errors.to_envelope(conn)

    %{error: Map.delete(env, :status)}
  end

  defp reason_for_template("404" <> _, _assigns), do: {:error, :not_found}

  # TYPED CONTENT REFUSAL pass-through. `Barkpark.Content.InvalidFilterError` is
  # raised at the query builder's chokepoint (`Content.Query.apply_filter_map/2`)
  # so that EVERY read door refuses an unsupported filter op instead of silently
  # returning the unfiltered set. Its `Plug.Exception` status is already 400; this
  # clause is what keeps the BODY canonical too — without it a builder-raised
  # refusal collapses to the generic `internal_error` code and an SDK/CLI reading
  # `error.code` cannot tell a bad filter from a server fault.
  #
  # Only THIS struct is passed through, and `Errors.build/1` re-derives its
  # message from the struct's `op` alone — the general "never speak an exception's
  # message" rule in the moduledoc above still holds for every other fault.
  defp reason_for_template(_template, %{
         kind: :error,
         reason: %Barkpark.Content.InvalidFilterError{} = e
       }),
       do: {:error, e}

  # SAME pass-through, for the task doors' one typed refusal
  # (`Barkpark.Tasks.AmbiguousTwinError`, THE ONE RULE — see
  # `Barkpark.Tasks.TwinResolver`). Its `Plug.Exception` status is already 409;
  # this clause is what keeps the BODY canonical, so a caller reading
  # `error.code` sees `ambiguous_dataset` with `details.datasets` — the one fact
  # that lets it retry with `?dataset=` — instead of a generic `internal_error`
  # that reads as a server fault and invites a blind retry forever.
  defp reason_for_template(_template, %{
         kind: :error,
         reason: %Barkpark.Tasks.AmbiguousTwinError{} = e
       }),
       do: {:error, e}

  defp reason_for_template(_template, assigns) do
    # A BINARY reason is carried verbatim as the message under the SAME
    # `internal_error` code (Errors.build/1); anything else falls back to the
    # generic builder text. Rendering with an empty assigns map (no fault in
    # scope at all) therefore still says exactly "unknown error".
    case fault_family(Map.get(assigns, :kind), Map.get(assigns, :reason)) do
      nil -> {:error, :unknown}
      family -> {:error, "unknown error (#{family})"}
    end
  end

  # RenderErrors passes `:kind` alongside `:reason`, and the two are NOT
  # interchangeable: for `:error` it has already run `Exception.normalize/3`, so
  # the reason is an exception STRUCT, while `:exit` and `:throw` hand over a
  # BARE TERM. Branching on the kind is what keeps this function total — a
  # struct-field read against a bare term would raise inside the error renderer
  # itself, the one place a raise costs the client its response entirely.
  # (No unwrap step for Plug.Conn.WrapperError: RenderErrors destructures it
  # before the view is ever called, so the inner exception is what arrives.)
  defp fault_family(_kind, nil), do: nil
  defp fault_family(:error, %{__struct__: mod}), do: inspect(mod)
  defp fault_family(:exit, reason), do: exit_family(reason)
  defp fault_family(_kind, _reason), do: nil

  # An exit payload is caller data (`GenServer.call` argument lists ride in the
  # tail), so only a fixed allowlist of HEAD atoms is ever spoken; anything else
  # degrades to the bare word "exit".
  @exit_heads [:timeout, :noproc, :noconnection, :shutdown, :killed]

  defp exit_family({head, _payload}) when head in @exit_heads, do: "exit: #{head}"
  defp exit_family(head) when head in @exit_heads, do: "exit: #{head}"
  defp exit_family(_other), do: "exit"
end
