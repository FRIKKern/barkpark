defmodule Barkpark.Plugins.Indx.Errors do
  @moduledoc """
  Error structs returned by `Barkpark.Plugins.Indx.Client` /
  `Barkpark.Plugins.Indx.Auth`.

  Each error is a discrete struct so the indexer / retriever / worker can
  pattern match without parsing strings:

    * `AuthError`    — login failed, or a 401 survived a token refresh
    * `IndexError`   — index / load / status / dataset-management failure
    * `SearchError`  — query-path failure (Search / GetJson)
    * `NetworkError` — transport-level (timeout, refused, closed)

  ## Redaction policy

  All four structs implement `Inspect` to scrub the Indx JWT and the
  configured user password out of dumps & logs:

    * Header keys `"authorization"` / `"Authorization"` are replaced with
      `"[REDACTED]"`.
    * Body content (string or map) is scanned for the JSON keys `token`,
      `authorization`, `password`, `userPassWord`, `UserPassWord`; matching
      VALUES are replaced with `"[REDACTED]"`.

  This keeps `inspect/1`, `Logger.error("\#{inspect(err)}")`, and ExUnit
  failure dumps free of the bearer token and the single-tenant credentials.
  Mirrors the OnixEdit/Bokbasen tagged-error-struct precedent.
  """

  @sensitive_header_keys ["authorization", "Authorization"]
  @sensitive_json_keys [
    "token",
    "authorization",
    "password",
    "userPassWord",
    "UserPassWord"
  ]

  defmodule AuthError do
    @moduledoc "Login failed, or a 401 survived a token refresh."
    @enforce_keys [:status]
    defstruct [:status, :endpoint, :message]

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            endpoint: String.t() | nil,
            message: String.t() | nil
          }
  end

  defmodule IndexError do
    @moduledoc "Index / load / status / dataset-management failure (non-401)."
    @enforce_keys [:status, :endpoint]
    defstruct [:status, :body, :endpoint, :message]

    @type t :: %__MODULE__{
            status: integer(),
            body: any(),
            endpoint: String.t(),
            message: String.t() | nil
          }
  end

  defmodule SearchError do
    @moduledoc "Query-path failure (Search / GetJson)."
    @enforce_keys [:status, :endpoint]
    defstruct [:status, :body, :endpoint, :message]

    @type t :: %__MODULE__{
            status: integer(),
            body: any(),
            endpoint: String.t(),
            message: String.t() | nil
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

  @doc """
  Recursively redact the Indx JWT and user password out of a value.

  Delegates to `Barkpark.Redaction` (the one shared engine) with THIS module's
  allowlists. Used by the `Inspect` impls below; exported for the test suite.
  """
  @spec redact(any()) :: any()
  def redact(value),
    do: Barkpark.Redaction.redact(value, @sensitive_header_keys, @sensitive_json_keys)

  defimpl Inspect, for: AuthError do
    import Inspect.Algebra

    def inspect(%{status: s, endpoint: e, message: m}, opts) do
      concat([
        "#Indx.AuthError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: IndexError do
    import Inspect.Algebra
    alias Barkpark.Plugins.Indx.Errors

    def inspect(%{status: s, body: b, endpoint: e, message: m}, opts) do
      concat([
        "#Indx.IndexError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ", body: ",
        to_doc(Errors.redact(b), opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: SearchError do
    import Inspect.Algebra
    alias Barkpark.Plugins.Indx.Errors

    def inspect(%{status: s, body: b, endpoint: e, message: m}, opts) do
      concat([
        "#Indx.SearchError<status: ",
        to_doc(s, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ", message: ",
        to_doc(m, opts),
        ", body: ",
        to_doc(Errors.redact(b), opts),
        ">"
      ])
    end
  end

  defimpl Inspect, for: NetworkError do
    import Inspect.Algebra

    def inspect(%{reason: r, endpoint: e}, opts) do
      concat([
        "#Indx.NetworkError<reason: ",
        to_doc(r, opts),
        ", endpoint: ",
        to_doc(e, opts),
        ">"
      ])
    end
  end
end
