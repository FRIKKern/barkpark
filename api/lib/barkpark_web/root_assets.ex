defmodule BarkparkWeb.RootAssets.Splitter do
  @moduledoc false
  # The compile-time cut described in `BarkparkWeb.RootAssets`. A separate
  # module so the module body of `RootAssets` can call it.

  @style_open "<style>"
  @style_close "</style>"
  @script_open "<script nonce={assigns[:csp_nonce]}>"
  @script_close "</script>"
  @paper_expr "<%= paper_stylesheet() %>"

  @doc """
  Cut the extractable blocks out of the root template `source`.

  Returns `{new_source, assets}`, where `assets` is a list of
  `{name, kind, parts}`: `kind` is `:css` or `:js`, and `parts` is a list of
  literal binaries and `:paper_stylesheet` markers, in order.
  """
  @spec split(String.t()) :: {String.t(), [{String.t(), :css | :js, list()}]}
  def split(source) do
    lines = String.split(source, "\n")
    {out, assets, _state} = walk(lines, [], [], %{in_body: false, css: 0, js: 0})
    {Enum.join(Enum.reverse(out), "\n"), Enum.reverse(assets)}
  end

  defp walk([], out, assets, state), do: {out, assets, state}

  defp walk([line | rest], out, assets, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "</head>" ->
        walk(rest, [line | out], assets, %{state | in_body: true})

      trimmed == @style_open ->
        {body, rest, n} = take_block(rest, @style_close, [])
        name = "studio-root-#{state.css + 1}.css"
        tag = ~s|<link rel="stylesheet" href={BarkparkWeb.RootAssets.path("#{name}")} />|
        out = [indent(line) <> tag <> filler(n) | out]
        walk(rest, out, [{name, :css, parts(body)} | assets], %{state | css: state.css + 1})

      trimmed == @script_open and state.in_body ->
        {body, rest, n} = take_block(rest, @script_close, [])
        name = "studio-root-#{state.js + 1}.js"
        tag = ~s|<script src={BarkparkWeb.RootAssets.path("#{name}")}></script>|
        out = [indent(line) <> tag <> filler(n) | out]
        walk(rest, out, [{name, :js, parts(body)} | assets], %{state | js: state.js + 1})

      true ->
        walk(rest, [line | out], assets, state)
    end
  end

  # The block's lines up to (not including) the closing line, the rest after
  # it, and how many lines were consumed after the opening line.
  defp take_block([line | rest], close, acc) do
    if String.trim(line) == close,
      do: {Enum.reverse(acc), rest, length(acc) + 1},
      else: take_block(rest, close, [line | acc])
  end

  defp take_block([], close, _acc),
    do: raise(ArgumentError, "root.html.heex: a block is never closed by #{close}")

  defp indent(line),
    do: String.duplicate(" ", String.length(line) - String.length(String.trim_leading(line)))

  # A HEEx comment over the cut lines keeps later line numbers where they were.
  defp filler(n), do: "<%!--" <> String.duplicate("\n", n) <> "--%>"

  defp parts(lines) do
    text = Enum.join(lines, "\n") <> "\n"

    pieces =
      text
      |> String.split(@paper_expr)
      |> Enum.intersperse(:paper_stylesheet)

    for piece <- pieces, is_binary(piece) do
      if String.contains?(piece, "<%"),
        do: raise(ArgumentError, "root.html.heex: an extracted block holds an EEx tag")
    end

    pieces
  end
end

defmodule BarkparkWeb.RootAssets do
  @moduledoc """
  Serves the root layout's inline stylesheets and body scripts as cacheable
  files (task-cca3c6d48e57097e).

  ## Why

  `layouts/root.html.heex` carried about 390 KB of inline CSS and 110 KB of
  inline script. Every page that uses the root layout, a Studio document open
  among them, downloaded and parsed those bytes again: on gyl the HTML of a
  document open is about 150 KB gzipped. As files with a content hash in the
  URL they are fetched once per deploy and then come from the browser cache.

  ## How

  The source stays where it was: `root.html.heex` is still the one file that
  holds these rules and scripts, and it is what reviewers and tests read. At
  compile time `Splitter.split/1` cuts each block out of the template source:

    * every `<style>` block (a line that is exactly `<style>` up to the next
      line that is exactly `</style>`), and
    * every `<script nonce={assigns[:csp_nonce]}>` block after `</head>`.

  The head's pre-paint script stays inline: it must run before first paint.

  Each block is replaced by a `<link rel="stylesheet">` or a classic
  `<script src>` at the same place, so the cascade order and the script
  execution order are unchanged. A HEEx comment takes up the cut lines, so
  every line after a cut keeps its line number in compile errors.

  The one EEx expression inside a block, `<%= paper_stylesheet() %>`, is
  evaluated when the asset body is first asked for. A block holding any other
  EEx tag fails the compile.

  ## Serving

  `BarkparkWeb.Plugs.RootAssets` answers `/assets/root/<hash>/<name>`. When
  the hash is the current one the answer is cached for a year as
  `immutable`. An old hash, from a page rendered before a deploy, gets the
  current body with `no-cache`.
  """

  @template Path.expand("layouts/root.html.heex", __DIR__)
  @external_resource @template

  @doc false
  def template_path, do: @template

  # ── Compile-time split of the template ─────────────────────────────────

  {source, assets} = BarkparkWeb.RootAssets.Splitter.split(File.read!(@template))
  @root_source source
  @assets assets
  # Part of the cache key, so a recompiled template or paper stylesheet never
  # serves the bodies built from the one before it (the dev code reloader
  # keeps the node up). Reading the stylesheet here also makes this module
  # recompile when it changes.
  @source_digest :erlang.phash2({assets, Barkpark.PortableDoc.Render.Stylesheet.css()})

  @doc false
  def root_source, do: @root_source

  @doc "The names of the extracted assets, in page order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@assets, &elem(&1, 0))

  @doc """
  The asset `name`: `{content_type, body, hash}`, built on first use and kept
  in `:persistent_term`. `nil` for an unknown name.
  """
  @spec fetch(String.t()) :: {String.t(), binary(), String.t()} | nil
  def fetch(name) do
    key = {__MODULE__, @source_digest, name}

    case :persistent_term.get(key, nil) do
      nil ->
        case List.keyfind(@assets, name, 0) do
          nil ->
            nil

          {^name, kind, parts} ->
            body = IO.iodata_to_binary(Enum.map(parts, &render_part/1))

            hash =
              :crypto.hash(:sha256, body)
              |> Base.url_encode64(padding: false)
              |> binary_part(0, 16)

            value = {content_type(kind), body, hash}
            :persistent_term.put(key, value)
            value
        end

      value ->
        value
    end
  end

  @doc "The URL of the asset `name`, with its content hash."
  @spec path(String.t()) :: String.t()
  def path(name) do
    {_type, _body, hash} = fetch(name) || raise ArgumentError, "unknown root asset #{name}"
    "/assets/root/#{hash}/#{name}"
  end

  defp render_part(:paper_stylesheet), do: Barkpark.PortableDoc.Render.Stylesheet.css()
  defp render_part(text) when is_binary(text), do: text

  defp content_type(:css), do: "text/css; charset=utf-8"
  defp content_type(:js), do: "text/javascript; charset=utf-8"
end

defmodule BarkparkWeb.RootAssets.Compiler do
  @moduledoc false
  # Compiles the root layout from `BarkparkWeb.RootAssets.root_source/0` with
  # the same options `Phoenix.LiveView.HTMLEngine` uses for a `.heex` file.
  defmacro compile_root do
    source = BarkparkWeb.RootAssets.root_source()

    EEx.compile_string(source,
      engine: Phoenix.LiveView.TagEngine,
      line: 1,
      file: BarkparkWeb.RootAssets.template_path(),
      trim: Application.get_env(:phoenix, :trim_on_html_eex_engine, true),
      caller: __CALLER__,
      source: source,
      tag_handler: Phoenix.LiveView.HTMLEngine
    )
  end
end
