defmodule BarkparkCloud.GitHub.LatestRelease do
  @moduledoc """
  The newest server release on GitHub, read the same way a box reads it.

  A box's checker (`api/lib/barkpark/self_update/client/github.ex`) lists
  `GET /repos/FRIKKern/barkpark/tags?per_page=100` and takes the highest bare
  `vA.B.C` tag. This module makes the same call and applies the same rule, so
  "GitHub has a release the box does not report" means the box's own next check
  would find it.

  The call is conditional. The last `etag` rides as `If-None-Match`, and a 304
  reuses the cached answer. The repo is public and the call is anonymous, so it
  draws on the 60 requests/hour budget of Cloud's address, which the
  commit-distance sweep shares. GitHub documents 304s as free only for
  authenticated requests, so the caller's cadence must fit the budget on its
  own: one call every 3 minutes is 20 an hour.

  The cache lives in `:persistent_term` on the node that runs the job. It holds
  the etag, the release, the commit its tag points at, and `observed_at`, the
  time this node first saw that release. A restart loses it, which costs one
  full 200 response and resets `observed_at` to the restart time.

  The commit is the tag's peeled commit sha, as the tags list reports it under
  `commit.sha`. `GET /v1/barkparks` serves it on every row as
  `latest_release_commit` (decision 0011), so a reader can tell a box that runs
  the latest release from a box that is behind it. It is nil until the first
  successful read after a boot, and nil when the tag carries no usable sha.

  Never raises. Every failure is `{:error, reason}`.

  Options: `:http_client` (1-arity fun or a module exporting
  `request_with_headers/1`) and `:repo`. Both also read from
  `config :barkpark_cloud, BarkparkCloud.GitHub.LatestRelease`.
  """

  @api_base "https://api.github.com"
  @default_repo "FRIKKern/barkpark"
  @cache_key {__MODULE__, :cache}
  @release_tag_re ~r/^v(\d+)\.(\d+)\.(\d+)$/

  @headers [
    {"user-agent", "barkpark-cloud-release-watch"},
    {"accept", "application/vnd.github+json"}
  ]

  @type entry :: %{
          release: String.t(),
          commit: String.t() | nil,
          observed_at: DateTime.t(),
          etag: String.t() | nil
        }

  @sha_re ~r/^[0-9a-f]{40}$/

  @doc """
  The newest `A.B.C` release, with the time this node first saw it.
  """
  @spec fetch(keyword()) :: {:ok, entry()} | {:error, term()}
  def fetch(opts \\ []) do
    cached = cached()

    headers =
      if cached && cached.etag, do: [{"if-none-match", cached.etag} | @headers], else: @headers

    request = %{method: :get, url: url(opts), headers: headers, body: ""}

    case call(opts, request) do
      {:ok, %{status: 304}} when cached != nil ->
        {:ok, cached}

      {:ok, %{status: 200, body: body} = resp} ->
        with {:ok, tags} when is_list(tags) <- Jason.decode(body),
             release when is_binary(release) <- max_release(tags) do
          {:ok, remember(cached, release, release_commit(tags, release), etag_of(resp))}
        else
          nil -> {:error, :no_release_tags}
          _ -> {:error, :unusable_body}
        end

      {:ok, %{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_client_result, other}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  @doc """
  The highest bare `vA.B.C` tag name in a GitHub tags list, as `"A.B.C"`, or nil.
  """
  @spec max_release([map()]) :: String.t() | nil
  def max_release(tags) do
    tags
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) ->
        case parse(name) do
          {:ok, v} -> [v]
          :error -> []
        end

      _ ->
        []
    end)
    |> case do
      [] -> nil
      versions -> versions |> Enum.max() |> format()
    end
  end

  @doc """
  The commit sha the `vA.B.C` tag for `release` points at, from a GitHub tags
  list, or nil when the tag is missing or its sha is not a full lowercase hex
  sha.
  """
  @spec release_commit([map()], String.t()) :: String.t() | nil
  def release_commit(tags, release) when is_list(tags) and is_binary(release) do
    name = "v" <> release

    Enum.find_value(tags, fn
      %{"name" => ^name, "commit" => %{"sha" => sha}} when is_binary(sha) ->
        sha = String.downcase(sha)
        if Regex.match?(@sha_re, sha), do: sha

      _ ->
        nil
    end)
  end

  def release_commit(_tags, _release), do: nil

  @doc """
  The cached latest release and its commit, without a network call. Returns
  `%{release: nil, commit: nil}` when this node has not read the tags yet.
  """
  @spec cached_latest() :: %{release: String.t() | nil, commit: String.t() | nil}
  def cached_latest do
    case cached() do
      %{release: release} = entry -> %{release: release, commit: Map.get(entry, :commit)}
      _ -> %{release: nil, commit: nil}
    end
  end

  @doc """
  Parse `"A.B.C"` or `"vA.B.C"` into an integer 3-tuple, as the box compares.
  """
  @spec parse(term()) :: {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | :error
  def parse("v" <> _ = tag), do: do_parse(tag)
  def parse(release) when is_binary(release), do: do_parse("v" <> release)
  def parse(_other), do: :error

  defp do_parse(tag) do
    case Regex.run(@release_tag_re, tag) do
      [_, a, b, c] -> {:ok, {String.to_integer(a), String.to_integer(b), String.to_integer(c)}}
      _ -> :error
    end
  end

  @doc false
  def reset, do: :persistent_term.erase(@cache_key)

  defp format({a, b, c}), do: "#{a}.#{b}.#{c}"

  defp cached, do: :persistent_term.get(@cache_key, nil)

  # A new release gets a new `observed_at`. The same release with a new etag
  # (another tag such as cli-v* was pushed) keeps the old one.
  defp remember(cached, release, commit, etag) do
    observed_at =
      case cached do
        %{release: ^release, observed_at: at} -> at
        _ -> DateTime.utc_now()
      end

    entry = %{release: release, commit: commit, observed_at: observed_at, etag: etag}
    if entry != cached, do: :persistent_term.put(@cache_key, entry)
    entry
  end

  defp etag_of(%{headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "etag", do: v end)
  end

  defp etag_of(_resp), do: nil

  defp url(opts), do: "#{@api_base}/repos/#{config(opts, :repo, @default_repo)}/tags?per_page=100"

  defp call(opts, request) do
    case config(opts, :http_client, BarkparkCloud.Billing.HttpClient) do
      fun when is_function(fun, 1) -> fun.(request)
      nil -> {:error, :no_http_client}
      mod when is_atom(mod) -> mod.request_with_headers(request)
    end
  end

  defp config(opts, key, default) do
    Keyword.get(opts, key) ||
      :barkpark_cloud |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
