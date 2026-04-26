defmodule Barkpark.Validation.Checkers.Iso4217Currency do
  @moduledoc """
  ISO-4217 currency-code checker (subset).

  Phase 3 ships a hardcoded subset covering every major active currency
  used in publishing pricing. The full ISO-4217 list belongs in the
  codelist registry (WI3) — this checker exists so rule authors have a
  zero-dependency way to reject obvious typos.
  """

  @behaviour Barkpark.Validation.Checker

  @codes MapSet.new(~w(
    USD EUR GBP JPY CHF AUD CAD NZD SEK NOK DKK ISK
    SGD HKD CNY KRW INR ZAR BRL MXN ARS CLP COP PEN
    PLN CZK HUF RON BGN HRK RUB UAH TRY ILS AED SAR
    THB IDR MYR PHP VND TWD
  ))

  @impl true
  def check(value, _args) when is_binary(value) do
    code = String.upcase(value)

    if MapSet.member?(@codes, code) do
      :ok
    else
      {:error, :unknown_currency}
    end
  end

  def check(_value, _args), do: {:error, :not_a_string}

  @doc "All recognised ISO-4217 codes in the bundled subset."
  @spec codes() :: MapSet.t()
  def codes, do: @codes
end
