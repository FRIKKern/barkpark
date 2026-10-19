defmodule BarkparkWeb.RootAssetsInline do
  @moduledoc """
  The served page as the browser assembles it: every root layout asset link
  (`BarkparkWeb.RootAssets`) replaced by the asset body, in place.

  For tests that assert a rule or script is SHIPPED with the page. Since
  task-cca3c6d48e57097e those bytes travel as `/assets/root/<hash>/<name>`
  files rather than inline in the HTML.
  """

  @link ~r{<link rel="stylesheet" href="/assets/root/[^/"]+/([^"]+)"\s*/?>}
  @script ~r{<script src="/assets/root/[^/"]+/([^"]+)"></script>}

  @spec inline(String.t()) :: String.t()
  def inline(html) when is_binary(html) do
    html
    |> replace(@link, "<style>", "</style>")
    |> replace(@script, "<script>", "</script>")
  end

  defp replace(html, regex, open, close) do
    Regex.replace(regex, html, fn whole, name ->
      case BarkparkWeb.RootAssets.fetch(name) do
        {_type, body, _hash} -> open <> body <> close
        nil -> whole
      end
    end)
  end
end
