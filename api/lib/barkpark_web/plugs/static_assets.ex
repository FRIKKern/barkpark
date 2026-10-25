defmodule BarkparkWeb.Plugs.StaticAssets do
  @moduledoc """
  Answers `GET`/`HEAD /assets/v/<hash>/<name>` with the file `<name>` from
  `priv/static/assets` (task-66122189b7af6ea2, `BarkparkWeb.StaticAssets`).

  The plug hashes the file's bytes as they are on disk now. When that hash
  is the one in the URL, the answer is `cache-control: public,
  max-age=31536000, immutable`: the URL changes whenever the bytes do, so a
  browser never needs to ask again. Any other hash is a page rendered before
  a deploy, or one rendered while the file was being replaced; it gets the
  current bytes with `no-cache`, the policy of the unversioned names. A name
  that is not a file falls through to the rest of the endpoint.

  The bytes go out through `Plug.Static`, so etags, `HEAD` and the `.gz` and
  `.br` siblings work as they do for the unversioned names. A sibling is
  used only when its mtime equals the file's, the rule the slot deploy keeps
  (`sync_static_siblings` in deploy/instance-deploy.sh). A sibling left over
  from the bytes before a deploy would otherwise be cached for a year under
  the new hash.

  Options: `compress:` turns the siblings on, as `gzip:` and `brotli:` do on
  the endpoint's `Plug.Static`.
  """
  @behaviour Plug

  alias BarkparkWeb.StaticAssets

  @immutable "public, max-age=31536000, immutable"

  @impl true
  def init(opts) do
    compress = Keyword.get(opts, :compress, false)

    for cache <- [:immutable, :no_cache], zip <- [true, false], into: %{} do
      cc = if cache == :immutable, do: @immutable, else: "no-cache"

      {{cache, zip},
       Plug.Static.init(
         at: "/",
         from: :barkpark,
         only: ["assets"],
         gzip: zip and compress,
         brotli: zip and compress,
         headers: %{"cache-control" => cc},
         cache_control_for_etags: cc
       )}
    end
  end

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["assets", "v", hash, name]} = conn, statics)
      when method in ["GET", "HEAD"] do
    case StaticAssets.fresh_hash(name) do
      nil ->
        conn

      current ->
        cache = if current == hash, do: :immutable, else: :no_cache
        zip = siblings_match?(StaticAssets.file(name))

        result =
          %{conn | path_info: ["assets", name], request_path: "/assets/" <> name}
          |> Plug.Static.call(Map.fetch!(statics, {cache, zip}))

        if result.halted,
          do: result,
          else: %{result | path_info: conn.path_info, request_path: conn.request_path}
    end
  end

  def call(conn, _statics), do: conn

  # True when every `.gz` and `.br` sibling that exists has the file's mtime.
  defp siblings_match?(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        Enum.all?([".gz", ".br"], fn ext ->
          case File.stat(file <> ext, time: :posix) do
            {:ok, %{mtime: ^mtime}} -> true
            {:ok, _} -> false
            {:error, _} -> true
          end
        end)

      {:error, _} ->
        false
    end
  end
end
