defmodule Barkpark.Accounts.Hibp do
  @moduledoc """
  Breached-password check via the Have I Been Pwned range API, using
  **k-anonymity**: only the first 5 hex chars of the password's SHA-1 leave this
  process; HIBP returns every breached suffix under that prefix and we match
  locally. The password itself is never transmitted.

  Opt-in (`config :barkpark, hibp_enabled: true`) so a self-hoster without
  outbound network loses nothing, and **fails OPEN**: if HIBP is unreachable the
  password is allowed (availability > this defence). The HTTP layer is a
  swappable behaviour (`:hibp_http`) so the k-anonymity property is testable
  without a network call.
  """

  @callback range(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "True when the breach check is enabled (default false)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:barkpark, :hibp_enabled, false)

  @http_impl_key :hibp_http
  defp http, do: Application.get_env(:barkpark, @http_impl_key, __MODULE__.ReqClient)

  @doc """
  `true` when `password` appears in a known breach corpus. Only the SHA-1
  prefix is sent. Returns `false` (fail-open) when the check is disabled or HIBP
  is unreachable.
  """
  @spec breached?(String.t()) :: boolean()
  def breached?(password) when is_binary(password) do
    if enabled?(), do: do_breached?(password), else: false
  end

  def breached?(_), do: false

  defp do_breached?(password) do
    <<prefix::binary-size(5), suffix::binary>> =
      :crypto.hash(:sha, password) |> Base.encode16(case: :upper)

    case http().range(prefix) do
      {:ok, body} -> suffix_present?(body, suffix)
      # Fail OPEN: never block a signup/reset because HIBP is down.
      {:error, _} -> false
    end
  end

  # The range body is `SUFFIX:COUNT` lines; the password is breached iff its
  # suffix is listed with a non-zero count.
  defp suffix_present?(body, suffix) do
    body
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      case String.split(line, ":", parts: 2) do
        [s, count] -> String.upcase(String.trim(s)) == suffix and parse_count(count) > 0
        _ -> false
      end
    end)
  end

  defp parse_count(c) do
    case c |> String.trim() |> Integer.parse() do
      {n, _} -> n
      :error -> 0
    end
  end

  defmodule ReqClient do
    @moduledoc false
    @behaviour Barkpark.Accounts.Hibp

    @impl true
    def range(prefix) do
      case Req.get("https://api.pwnedpasswords.com/range/#{prefix}",
             headers: [{"add-padding", "true"}],
             retry: false,
             receive_timeout: 3_000
           ) do
        {:ok, %{status: 200, body: body}} -> {:ok, to_string(body)}
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
