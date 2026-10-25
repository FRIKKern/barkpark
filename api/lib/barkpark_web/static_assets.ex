defmodule BarkparkWeb.StaticAssets do
  @moduledoc """
  Content-hashed URLs for the `/assets` files the root layout links
  (task-66122189b7af6ea2).

  ## Why

  `layouts/root.html.heex` links 27 files from `priv/static/assets`
  (`phoenix.js`, `phoenix_live_view.js`, the `bp-*.js` scripts and two
  `bp-*.css` stylesheets). `Plug.Static` serves those names with
  `cache-control: no-cache` on purpose: the name does not change when the
  bytes do (endpoint.ex, cch charter D139). So every Studio open asked for
  all 27 again and got 27 answers of 304.

  ## How

  `path/1` turns `"bp-graph.js"` into `/assets/v/<hash>/bp-graph.js`, where
  `<hash>` is the first 16 characters of the url-safe base64 SHA-256 of the
  file's bytes. A new deploy that changes the bytes changes the URL, so the
  browser may keep the old URL's bytes for a year.
  `BarkparkWeb.Plugs.StaticAssets` serves that URL.

  The hash is kept per file in `:persistent_term` together with the file's
  stat (size, mtime, ctime, inode), and computed again when the stat changes,
  so a page render costs one `stat` per file, not a read. The stat only
  decides when to hash again. It never stands in for the content: the plug
  hashes the bytes again before it answers with `immutable`, so a stale
  memo can only cost a `no-cache` answer, never a wrong cached file.

  The unversioned names keep working with `no-cache`, for pages and
  embedders that link them directly.
  """

  @prefix "/assets/v/"

  @doc "The URL prefix the hashed names are served under."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  The hashed URL of the file `name` in `priv/static/assets`. A missing file
  gets its plain `/assets/<name>` URL, the one `Plug.Static` answers.
  """
  @spec path(String.t()) :: String.t()
  def path(name) when is_binary(name) do
    case hash(name) do
      nil -> "/assets/" <> name
      hash -> @prefix <> hash <> "/" <> name
    end
  end

  @doc """
  The content hash of the file `name`, from the memo while the file's stat is
  unchanged. `nil` for a name that is not a regular file in the directory.
  """
  @spec hash(String.t()) :: String.t() | nil
  def hash(name) when is_binary(name) do
    with true <- valid_name?(name),
         file = file(name),
         {:ok, %File.Stat{type: :regular} = stat} <- File.stat(file, time: :posix) do
      sig = {stat.size, stat.mtime, stat.ctime, stat.inode}
      key = {__MODULE__, name}

      case :persistent_term.get(key, nil) do
        {^sig, hash} ->
          hash

        _ ->
          case fresh_hash(name) do
            nil ->
              nil

            hash ->
              :persistent_term.put(key, {sig, hash})
              hash
          end
      end
    else
      _ -> nil
    end
  end

  @doc """
  The content hash of the bytes of `name` as they are on disk now, read and
  hashed on every call. `nil` when the file cannot be read.
  """
  @spec fresh_hash(String.t()) :: String.t() | nil
  # SAFE: the path is `dir()` joined with a name that `valid_name?/1` has
  # limited to letters, digits, dot, dash and underscore, not starting with a
  # dot. No slash and no `..` segment can reach `File.read`, so the read
  # stays inside priv/static/assets, the directory Plug.Static serves anyway.
  # sobelow_skip ["Traversal.FileModule"]
  def fresh_hash(name) when is_binary(name) do
    with true <- valid_name?(name),
         {:ok, body} <- File.read(file(name)) do
      digest(body)
    else
      _ -> nil
    end
  end

  @doc "The hash of `body` as it appears in a URL."
  @spec digest(binary()) :: String.t()
  def digest(body) when is_binary(body) do
    :crypto.hash(:sha256, body)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  @doc """
  True for a plain file name: letters, digits, dot, dash and underscore, not
  starting with a dot. Nothing with a slash or `..` can reach the disk.
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name), do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name)

  @doc "The directory the names resolve in."
  @spec dir() :: String.t()
  def dir, do: Application.app_dir(:barkpark, "priv/static/assets")

  @doc false
  def file(name), do: Path.join(dir(), name)
end
