defmodule Barkpark.Validation.Checkers.Iso639Language do
  @moduledoc """
  Lightweight ISO-639-2/T language-code checker.

  Phase 3 ships a hardcoded subset of the ~7000 ISO-639-3 codes. The
  list covers every language emitted by the seed/onixedit fixtures and
  every major publishing language. WI3's codelist registry will own
  the full set; this checker is intentionally small so rules can fire
  in the boot path without loading a registry.
  """

  @behaviour Barkpark.Validation.Checker

  @codes MapSet.new(~w(
    eng spa fre fra ger deu ita por nld swe nor nob nno dan fin ice isl
    rus ukr pol ces slk hun ron bul srp hrv slv mkd lit lav est ell tur
    ara heb fas urd hin ben tam tel mar guj kan mal pan
    zho cmn yue jpn kor tha vie ind msa fil tgl
    lat grc afr swa amh
    en es fr de it pt nl sv no da fi is ru uk pl cs sk hu ro bg sr hr sl mk lt lv et el tr ar he fa ur hi bn ta te mr gu kn ml pa zh ja ko th vi id ms tl la sw am
  ))

  @impl true
  def check(value, _args) when is_binary(value) do
    code = String.downcase(value)

    if MapSet.member?(@codes, code) do
      :ok
    else
      {:error, :unknown_language}
    end
  end

  def check(_value, _args), do: {:error, :not_a_string}

  @doc "All recognised codes (3-letter ISO-639-2/T plus 2-letter shorthands)."
  @spec codes() :: MapSet.t()
  def codes, do: @codes
end
