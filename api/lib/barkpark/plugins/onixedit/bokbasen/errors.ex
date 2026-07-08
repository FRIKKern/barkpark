defmodule Barkpark.Plugins.OnixEdit.Bokbasen.Errors do
  @moduledoc """
  Error structs returned by `Barkpark.Plugins.OnixEdit.Bokbasen.Client`.

  Each error is a discrete struct so the WI4 `PublishWorker` can pattern
  match without parsing strings:

    * `HTTPError`           — generic 4xx/5xx not covered by the others
    * `AuthError`           — 401/403 (worker may escalate)
    * `SchemaRejectionError`— 422 with parsed rejection details
    * `NetworkError`        — transport-level (timeout, refused, closed)
    * `RateLimitError`      — 429 with `Retry-After` budget exhausted

  ## Redaction policy

  All error structs implement `Inspect` to scrub bearer tokens and
  OAuth2 secrets out of dumps & logs:

    * Header keys `"authorization"` / `"Authorization"` are replaced with
      `"[REDACTED]"`.
    * Body content (string or map) is scanned for the JSON keys
      `access_token`, `client_secret`, `client_id`; matching VALUES are
      replaced with `"[REDACTED]"`.

  This keeps `inspect/1`, `Logger.error("\#{inspect(err)}")`, and ExUnit
  failure dumps free of long-lived credentials. See WI3 acceptance test
  `errors_test.exs` for the no-leak guarantees.
  """

  @sensitive_header_keys ["authorization", "Authorization"]
  @sensitive_json_keys ["access_token", "client_secret", "client_id"]

  defmodule HTTPError do
    @moduledoc "Generic HTTP error (4xx/5xx not specialised)."
    @enforce_keys [:status, :endpoint]
    defstruct [:status, :body, :headers, :endpoint]

    @type t :: %__MODULE__{
            status: pos_integer(),
            body: any(),
            headers: map() | list() | nil,
            endpoint: String.t()
          }
  end

  defmodule AuthError do
    @moduledoc "401/403 — credential refresh failed or scope rejected."
    @enforce_keys [:status]
    defstruct [:status, :endpoint, :message]

    @type t :: %__MODULE__{
            status: 401 | 403,
            endpoint: String.t() | nil,
            message: String.t() | nil
          }
  end

  defmodule SchemaRejectionError do
    @moduledoc "422 — Bokbasen rejected the ONIX submission as invalid."
    @enforce_keys [:rejection_details]
    defstruct [:rejection_details, :raw_body, :endpoint]

    @type t :: %__MODULE__{
            rejection_details: any(),
            raw_body: any(),
            endpoint: String.t() | nil
          }
  end

  defmodule NetworkError do
    @moduledoc "Transport-level failure (timeout, connection refused, closed)."
    @enforce_keys [:reason]
    defstruct [:reason, :endpoint]

    @type t :: %__MODULE__{
            reason: atom() | term(),
            endpoint: String.t() | nil
          }
  end

  defmodule RateLimitError do
    @moduledoc "429 — Retry-After budget exhausted; caller should back off."
    @enforce_keys [:retry_after_seconds]
    defstruct [:retry_after_seconds, :endpoint]

    @type t :: %__MODULE__{
            retry_after_seconds: non_neg_integer(),
            endpoint: String.t() | nil
          }
  end

  @doc """
  Recursively redact bearer tokens and OAuth2 secrets out of a value.

  Delegates to `Barkpark.Redaction` (the one shared engine) with THIS module's
  allowlists. Used by the `Inspect` impls below; exported for the test suite.
  """
  @spec redact(any()) :: any()
  def redact(value),
    do: Barkpark.Redaction.redact(value, @sensitive_header_keys, @sensitive_json_keys)

  defimpl Inspect, for: HTTPError do
    import Inspect.Algebra
    alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors

    def inspect(%{status: s, body: b, headers: h, endpoint: e}, opts) do
      concat([
        "#Bokbasen.HTTPError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", headers: ",
        to_doc(Errors.redact(h), opts),
        ", body: ",
        to_doc(Errors.redact(b), opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: AuthError do
    import Inspect.Algebra

    def inspect(%{status: s, endpoint: e, message: m}, opts) do
      concat([
        "#Bokbasen.AuthError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: SchemaRejectionError do
    import Inspect.Algebra
    alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors

    def inspect(%{rejection_details: d, raw_body: b, endpoint: e}, opts) do
      concat([
        "#Bokbasen.SchemaRejectionError<endpoint: ",
        to_doc(e, opts),
        ", rejection_details: ",
        to_doc(Errors.redact(d), opts),
        ", raw_body: ",
        to_doc(Errors.redact(b), opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: NetworkError do
    import Inspect.Algebra

    def inspect(%{reason: r, endpoint: e}, opts) do
      concat([
        "#Bokbasen.NetworkError<reason: ",
        to_doc(r, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: RateLimitError do
    import Inspect.Algebra

    def inspect(%{retry_after_seconds: n, endpoint: e}, opts) do
      concat([
        "#Bokbasen.RateLimitError<retry_after_seconds: ",
        to_doc(n, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ">"
      ])
    end
  end
end
