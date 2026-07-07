defmodule Barkpark.Plugins.Github.Errors do
  @moduledoc """
  Error structs returned by `Barkpark.Plugins.Github.Auth` and
  `Barkpark.Plugins.Github.Client`.

  Each error is a discrete struct so the wave-2 `MirrorJob` can pattern
  match without parsing strings:

    * `AuthError`      — App/installation auth failed (missing creds, bad
      private key, 401/403 that is NOT a rate limit, or a failed token
      refresh). `Auth.token/0` returns ONLY this error variant.
    * `RateLimitError` — 403/429 carrying `Retry-After` or
      `X-RateLimit-*` reset headers. Carries `retry_after` (seconds) so
      the Oban job can `{:snooze, retry_after}` (charter D9) — the client
      NEVER sleeps on a rate limit itself.
    * `NetworkError`   — transport failure (timeout, refused, closed) OR
      an unclassified non-2xx status (`reason: {:http, status}`); the
      wave-2 engine treats these as retryable.
    * `NotFound`       — 404/410. A deleted/transferred issue (410 Gone)
      lands here so the mirror can mark `github.state=detached` (D7)
      instead of recreating it.

  ## Redaction policy

  All structs implement `Inspect` to scrub bearer tokens out of dumps and
  logs: header key `"authorization"` and the JSON keys `token` /
  `access_token` are replaced with `"[REDACTED]"`. This keeps `inspect/1`,
  `Logger.error("\#{inspect(err)}")`, and ExUnit failure dumps free of the
  short-lived installation token.
  """

  @sensitive_header_keys ["authorization", "Authorization"]
  @sensitive_json_keys ["token", "access_token"]

  defmodule AuthError do
    @moduledoc "App/installation auth failure. The only error `Auth.token/0` returns."
    @enforce_keys [:status]
    defstruct [:status, :endpoint, :message]

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            endpoint: String.t() | nil,
            message: String.t() | nil
          }
  end

  defmodule RateLimitError do
    @moduledoc "403/429 with a rate-limit reset; `retry_after` in seconds."
    @enforce_keys [:retry_after]
    defstruct [:retry_after, :endpoint]

    @type t :: %__MODULE__{
            retry_after: non_neg_integer(),
            endpoint: String.t() | nil
          }
  end

  defmodule NetworkError do
    @moduledoc "Transport failure or an unclassified non-2xx (`reason: {:http, status}`)."
    @enforce_keys [:reason]
    defstruct [:reason, :endpoint]

    @type t :: %__MODULE__{
            reason: atom() | {:http, non_neg_integer()} | term(),
            endpoint: String.t() | nil
          }
  end

  defmodule NotFound do
    @moduledoc "404/410 — the issue/repo does not exist (410 Gone = detached)."
    @enforce_keys [:status]
    defstruct [:status, :endpoint, :message]

    @type t :: %__MODULE__{
            status: 404 | 410,
            endpoint: String.t() | nil,
            message: String.t() | nil
          }
  end

  @doc """
  Recursively redact bearer tokens out of a value.

  Used by the `Inspect` impls below; exported for the test suite.
  """
  @spec redact(any()) :: any()
  def redact(value), do: do_redact(value)

  defp do_redact(map) when is_map(map) and not is_struct(map) do
    Enum.into(map, %{}, fn {k, v} -> {k, redact_pair(k, v)} end)
  end

  defp do_redact(list) when is_list(list) do
    Enum.map(list, fn
      {k, v} -> {k, redact_pair(k, v)}
      other -> do_redact(other)
    end)
  end

  defp do_redact(bin) when is_binary(bin), do: redact_binary(bin)
  defp do_redact(other), do: other

  defp redact_pair(k, v) when is_binary(k) do
    cond do
      k in @sensitive_header_keys -> "[REDACTED]"
      k in @sensitive_json_keys -> "[REDACTED]"
      true -> do_redact(v)
    end
  end

  defp redact_pair(k, v) when is_atom(k), do: redact_pair(Atom.to_string(k), v)
  defp redact_pair(_k, v), do: do_redact(v)

  # Best-effort scrub of JSON-looking strings — replace any
  # `"<sensitive_key>":"..."` pair with `"<sensitive_key>":"[REDACTED]"`.
  defp redact_binary(bin) do
    Enum.reduce(@sensitive_json_keys, bin, fn key, acc ->
      Regex.replace(
        ~r/("#{Regex.escape(key)}"\s*:\s*)"[^"]*"/,
        acc,
        "\\1\"[REDACTED]\""
      )
    end)
  end

  defimpl Inspect, for: AuthError do
    import Inspect.Algebra

    def inspect(%{status: s, endpoint: e, message: m}, opts) do
      concat([
        "#Github.AuthError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: RateLimitError do
    import Inspect.Algebra

    def inspect(%{retry_after: n, endpoint: e}, opts) do
      concat([
        "#Github.RateLimitError<retry_after: ",
        to_doc(n, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: NetworkError do
    import Inspect.Algebra

    def inspect(%{reason: r, endpoint: e}, opts) do
      concat([
        "#Github.NetworkError<reason: ",
        to_doc(r, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: NotFound do
    import Inspect.Algebra

    def inspect(%{status: s, endpoint: e, message: m}, opts) do
      concat([
        "#Github.NotFound<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ">"
      ])
    end
  end
end
