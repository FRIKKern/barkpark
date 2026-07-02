defmodule Barkpark.SelfUpdate.Client.GitHub do
  @moduledoc """
  GitHub-backed `Barkpark.SelfUpdate.Client` — the default upstream source.

  Talks to the public GitHub REST API with Req (the api's sole outbound
  HTTP client): tags are listed via `GET /repos/:repo/tags` and the commit
  digest via `GET /repos/:repo/compare/:from...:to`. Unauthenticated —
  the 60 req/h anonymous rate limit is plenty for an hourly check.

  NOTE: only bare `vA.B.C` tags count as releases — the bp CLI's separate
  `cli-v*` tag space is excluded by construction (the regex anchors on
  exactly three numeric segments).

  Fail-closed: any non-200, transport error, or unexpected body shape
  returns `{:error, reason}`. This module never raises.
  """

  @behaviour Barkpark.SelfUpdate.Client

  @api_base "https://api.github.com"
  @headers [
    {"user-agent", "barkpark-self-update"},
    {"accept", "application/vnd.github+json"}
  ]
  @receive_timeout 10_000
  @release_tag_re ~r/^v(\d+)\.(\d+)\.(\d+)$/
  @digest_cap 50

  @impl true
  def latest_release(repo) do
    case request("#{@api_base}/repos/#{repo}/tags?per_page=100") do
      {:ok, tags} when is_list(tags) ->
        case tags |> Enum.map(&tag_name/1) |> max_release_tag() do
          nil -> {:error, :no_release_tags}
          {release, tag} -> {:ok, %{release: release, tag: tag}}
        end

      {:ok, _other} ->
        {:error, :unexpected_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def digest(repo, from_tag, to_tag) do
    case request("#{@api_base}/repos/#{repo}/compare/#{from_tag}...#{to_tag}") do
      {:ok, %{"commits" => commits}} when is_list(commits) ->
        lines =
          commits
          |> Enum.map(fn commit -> commit |> commit_message() |> first_line() end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(@digest_cap)

        {:ok, lines}

      {:ok, _other} ->
        {:error, :unexpected_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Pure tag-max logic, extracted so it is unit-testable without network
  # (see client_github_test.exs): keep names matching bare `vA.B.C`, parse
  # to integer 3-tuples, pick the max. Returns {"A.B.C", "vA.B.C"} | nil.
  @doc false
  @spec max_release_tag([String.t() | nil]) :: {String.t(), String.t()} | nil
  def max_release_tag(names) do
    names
    |> Enum.flat_map(fn name ->
      with true <- is_binary(name),
           [_, a, b, c] <- Regex.run(@release_tag_re, name) do
        [{{String.to_integer(a), String.to_integer(b), String.to_integer(c)}, name}]
      else
        _ -> []
      end
    end)
    |> case do
      [] ->
        nil

      parsed ->
        {{a, b, c}, tag} = Enum.max_by(parsed, fn {tuple, _name} -> tuple end)
        {"#{a}.#{b}.#{c}", tag}
    end
  end

  defp request(url) do
    case Req.get(url, headers: @headers, receive_timeout: @receive_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Req option/URL errors etc. — wrap, never let an exception escape.
    error -> {:error, error}
  end

  defp tag_name(%{"name" => name}), do: name
  defp tag_name(_other), do: nil

  defp commit_message(%{"commit" => %{"message" => message}}), do: message
  defp commit_message(_other), do: nil

  defp first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  defp first_line(_other), do: nil
end
