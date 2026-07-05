defmodule Barkpark.Sso.Domains.Resolver do
  @moduledoc """
  DNS TXT lookup behind a swappable behaviour so tests stand in a fake resolver
  (config `:dns_resolver`). Default uses Erlang's `:inet_res`.
  """
  @callback txt_records(String.t()) :: [String.t()]

  def impl, do: Application.get_env(:barkpark, :dns_resolver, __MODULE__.Inet)
  def txt_records(domain), do: impl().txt_records(domain)

  defmodule Inet do
    @moduledoc false
    @behaviour Barkpark.Sso.Domains.Resolver

    @impl true
    def txt_records(domain) do
      domain
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :txt)
      |> Enum.map(fn parts -> parts |> Enum.map(&to_string/1) |> Enum.join() end)
    rescue
      _ -> []
    end
  end
end
