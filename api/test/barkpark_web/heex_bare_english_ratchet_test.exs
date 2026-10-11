defmodule BarkparkWeb.HeexBareEnglishRatchetTest do
  @moduledoc """
  English typed straight into HEEx never reaches the catalog, so an nb page
  shows it in English. This counts it on the surfaces ruled Norwegian, and the
  count only comes down (run 8, the non-gettext audit).

  WHAT COUNTS. A HEEx text node, or a literal `title` / `aria-label` /
  `placeholder` / `alt`, with a real word in it, in a `~H` block or `.heex`
  file under `lib/barkpark_web` or `lib/barkpark/plugins/*/web`. Not counted:
  anything inside `{…}` or `<% %>` (that is where `gettext` lives), comments,
  `<script>`/`<style>`/`<code>`, entities, and codes rather than words (paths,
  env vars, emails, snippets, all-caps tokens, one-letter words, brand names). English string literals
  INSIDE `{…}` are out of reach of this scan; it is a floor, not a census.

  THE RULINGS (lead, run 8), on record here because this list is what the
  ratchet leaves out:

    nb, counted
      * A. Studio author core.
      * B. The sign-in pages (`session_html`), by Accept-Language, never the
           Default workspace's locale.
      * C. OnixEdit's console (staleness, Bokbasen, ping): used by Norwegian
           publisher staff, and Bokbasen is Norwegian.

    English, left out — with the reason
      * Tasks, Tickets, Pulse, the API tester: earlier rulings (operator and
        ops surfaces, and the API tester's labels stay English).
      * GitHub ops, plugin settings, org admin, server vitals: operator
        surfaces (C, the operator half).
      * The styleguide, chat, chat hosts, tmux: developer surfaces (D).

  THE NINE LEFT AT THE CEILING (measured on the tree that pinned it):
    * `finder_live.ex` — 5 (the public search page; it puts no locale, and its
      language is not yet ruled);
    * `layouts/studio.html.heex` — "Token", the API tester's label (an
      English-ruled surface that lives in the shared layout);
    * `layouts/bulldocs.html.heex` — "bp paper view", a CLI command in the
      terminal mock;
    * `paper_editor.ex` — the `lang` / `en` placeholders, language codes.

  The ceiling only comes down: a count above it reds, and so does a count
  below it, so the record is lowered in the same change that earns it.
  """
  use ExUnit.Case, async: true

  @ceiling 9

  @api Path.expand("../..", __DIR__)

  @english_ruled [
    {~r{tickets}i, "Tickets — operator surface"},
    {~r{pulse}i, "Pulse — ops surface"},
    {~r{api_tester}i, "API tester — labels stay English"},
    {~r{(/tasks|tasks_|task_board|task_live)}i, "Tasks — earlier ruling"},
    {~r{plugins/github/}, "GitHub ops — operator surface (C)"},
    {~r{admin/plugin_settings_live|admin/plugins_live},
     "plugin settings/list — operator surface (C)"},
    {~r{org_admin_live}, "org admin — operator surface (C)"},
    {~r{server_vitals_live}, "server vitals — operator surface (C)"},
    {~r{styleguide_live|swatch_live}, "styleguide — developer surface (D)"},
    {~r{chat_live|chat_hosts_live|chat_tool_renderer}, "chat — developer surface (D)"},
    {~r{tmux_live}, "tmux — developer surface (D)"}
  ]

  @brands ~w(Barkpark Studio GitHub Github Slack Teams Discord ONIX Bokbasen Sanity Kahoot
             Hyperquiz Markdown JSON HTML CSS URL API PDF CSV UTC TeX Lucide Quiz OnixEdit
             Mail Papers pdrender)

  test "bare English in the nb surfaces' HEEx is at its ceiling, and only comes down" do
    found =
      for {path, hits} <- scan_tree(), not english_ruled?(path), hit <- hits, do: {path, hit}

    assert length(found) <= @ceiling,
           "#{length(found)} bare English HEEx strings (ceiling #{@ceiling}) — wrap them in gettext:\n" <>
             Enum.map_join(Enum.take(found, 20), "\n", fn {p, h} -> "  #{p}: #{inspect(h)}" end)

    assert length(found) >= @ceiling,
           "the bare English count fell to #{length(found)}; lower @ceiling to it in this change"
  end

  # The counter sees what it should and nothing else.
  test "control: text nodes and labelled attributes count; gettext, codes and brands do not" do
    heex = ~S"""
    <h1>Codelist staleness</h1>
    <h2>{gettext("Wrapped")}</h2>
    <p><%= gettext("Also wrapped") %></p>
    <button aria-label="Close panel">&times;</button>
    <input placeholder={gettext("Search")} />
    <input placeholder="you@example.com" />
    <code>BARKPARK_SELF_UPDATE_APPLY</code>
    <p>Run <code>git pull</code></p>
    <span>/v1/auth/oidc</span>
    <span>Barkpark</span>
    <%!-- a comment with English words --%>
    <script>var label = "Show password";</script>
    """

    assert scan(heex) == [
             {"aria-label", "Close panel"},
             {"text", "Codelist staleness"},
             {"text", "Run"}
           ]
  end

  test "every left-out file is named by a ruling, and the left-out set is not empty" do
    left_out = for {path, _} <- scan_tree(), english_ruled?(path), do: path

    assert left_out != [],
           "no English-ruled file matched; the rulings list has drifted from the tree"
  end

  # ── the scan ────────────────────────────────────────────────────────────────

  defp english_ruled?(path),
    do: Enum.any?(@english_ruled, fn {re, _why} -> Regex.match?(re, path) end)

  defp scan_tree do
    ["lib/barkpark_web", "lib/barkpark/plugins"]
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join([@api, dir, "**", "*.{ex,heex}"])) end)
    |> Enum.map(fn path ->
      {Path.relative_to(path, @api), path |> blocks() |> Enum.flat_map(&scan/1)}
    end)
    |> Enum.reject(fn {_p, hits} -> hits == [] end)
  end

  defp blocks(path) do
    src = File.read!(path)

    if String.ends_with?(path, ".heex"),
      do: [src],
      else: Regex.scan(~r/~H"""(.*?)"""/s, src, capture: :all_but_first) |> List.flatten()
  end

  defp scan(heex) do
    t =
      heex
      |> String.replace(~r/<%!--.*?--%>/s, "")
      |> String.replace(~r/<!--.*?-->/s, "")
      |> String.replace(~r/<script\b.*?<\/script>/si, "")
      |> String.replace(~r/<style\b.*?<\/style>/si, "")
      |> String.replace(~r/<code\b.*?<\/code>/si, "")
      |> String.replace(~r/<%=?.*?%>/s, "")

    attrs =
      for [name, value] <-
            Regex.scan(~r/\b(title|aria-label|placeholder|alt)="([^"{}]*)"/, t,
              capture: :all_but_first
            ),
          wordy?(value),
          do: {name, String.trim(value)}

    texts =
      for [text] <- Regex.scan(~r/>([^<>]+)</, strip_braces(t), capture: :all_but_first),
          text = text |> String.replace(~r/\s+/, " ") |> String.trim(),
          text != "",
          wordy?(text),
          do: {"text", text}

    attrs ++ texts
  end

  # Drop every `{…}` expression, nested or not, keeping newlines.
  defp strip_braces(s) do
    {out, _depth} =
      s
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn
        "{", {acc, d} -> {acc, d + 1}
        "}", {acc, d} when d > 0 -> {acc, d - 1}
        c, {acc, 0} -> {[c | acc], 0}
        "\n", {acc, d} -> {["\n" | acc], d}
        _c, {acc, d} -> {acc, d}
      end)

    out |> Enum.reverse() |> Enum.join()
  end

  defp wordy?(s) do
    s = s |> String.replace(~r/&[a-zA-Z]+;|&#\d+;/, " ") |> String.trim()

    cond do
      not Regex.match?(~r/[A-Za-z]{2,}/, s) -> false
      Regex.match?(~r{[/@=_]|\w\.\w|-->|\(\)}, s) -> false
      Regex.match?(~r/^[A-Z0-9_ ]+$/, s) -> false
      true -> real_words?(s)
    end
  end

  defp real_words?(s) do
    ~r/[A-Za-z][A-Za-z'’-]+/
    |> Regex.scan(s)
    |> List.flatten()
    |> Enum.reject(fn w -> w in @brands or Regex.match?(~r/^[A-Z0-9_]{1,5}$/, w) end)
    |> Enum.any?()
  end
end
