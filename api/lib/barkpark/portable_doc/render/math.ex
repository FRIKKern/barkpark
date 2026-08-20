defmodule Barkpark.PortableDoc.Render.Math do
  @moduledoc """
  `equation` (B025) — server-side TeX -> MathML, zero client JS. Native
  `<math>` renders in every modern browser. A bounded, deterministic
  tokenizer/parser (NOT a full TeX engine): `\\frac{a}{b}`, `^`/`_`
  super/subscripts, and a fixed greek-letter/operator macro table. Anything
  outside that table degrades honestly to an `<mtext>` of the raw macro —
  never a fabricated render. This is the Elixir twin of pdrender's
  texToUnicode (equation.go) and the JS `math.ts` texToMathMlRow — same
  macro table and grammar, so all three surfaces agree on what a given TeX
  source produces.
  """

  alias Barkpark.PortableDoc.Render.Util

  @macros %{
    "\\alpha" => "α",
    "\\beta" => "β",
    "\\gamma" => "γ",
    "\\delta" => "δ",
    "\\epsilon" => "ε",
    "\\theta" => "θ",
    "\\lambda" => "λ",
    "\\mu" => "μ",
    "\\pi" => "π",
    "\\sigma" => "σ",
    "\\phi" => "φ",
    "\\omega" => "ω",
    "\\Delta" => "Δ",
    "\\Gamma" => "Γ",
    "\\Sigma" => "Σ",
    "\\Omega" => "Ω",
    "\\infty" => "∞",
    "\\sum" => "∑",
    "\\int" => "∫",
    "\\prod" => "∏",
    "\\partial" => "∂",
    "\\nabla" => "∇",
    "\\cdot" => "·",
    "\\times" => "×",
    "\\div" => "÷",
    "\\pm" => "±",
    "\\mp" => "∓",
    "\\leq" => "≤",
    "\\geq" => "≥",
    "\\neq" => "≠",
    "\\approx" => "≈",
    "\\equiv" => "≡",
    "\\to" => "→",
    "\\rightarrow" => "→",
    "\\leftarrow" => "←",
    "\\in" => "∈",
    "\\notin" => "∉",
    "\\subset" => "⊂",
    "\\cup" => "∪",
    "\\cap" => "∩",
    "\\forall" => "∀",
    "\\exists" => "∃",
    "\\sqrt" => "√"
  }

  @operators MapSet.new(~w[+ - = * / ( ) < > ,])

  @doc "Render an `equation` block to its full `<div class=\"bp-equation\">` article HTML."
  def equation_html(block) when is_map(block) do
    tex = block |> Map.get("tex", "") |> stringish() |> String.trim()

    if tex == "" do
      ~s|<div class="bp-equation bp-equation--empty">equation — no tex source</div>|
    else
      display = Map.get(block, "display") == true
      row = tex_to_mathml_row(tex)
      display_attr = if display, do: ~s( display="block"), else: ""
      ~s|<div class="bp-equation"><math#{display_attr}>#{row}</math></div>|
    end
  end

  def equation_html(_),
    do: ~s|<div class="bp-equation bp-equation--empty">equation — no tex source</div>|

  @doc "Email-safe equation: a degrade badge showing the raw TeX source."
  def equation_email_html(block) when is_map(block) do
    tex = block |> Map.get("tex", "") |> stringish() |> String.trim()

    if tex == "" do
      ~s|<div style="border:1px dashed #ccc;border-radius:10px;padding:10px 13px;color:#888;font-size:12px;margin:12px 0">equation — no tex source</div>|
    else
      ~s|<div style="border:1px solid #ddd;border-radius:10px;padding:10px 13px;font-family:monospace;font-size:13px;margin:12px 0">#{Util.escape_html(tex)}</div>|
    end
  end

  def equation_email_html(_),
    do:
      ~s|<div style="border:1px dashed #ccc;border-radius:10px;padding:10px 13px;color:#888;font-size:12px;margin:12px 0">equation — no tex source</div>|

  @doc "Convert one TeX math source string to a MathML row (no outer `<math>`)."
  def tex_to_mathml_row(tex) do
    {row, _rest} = parse_row(tokenize(tex))
    row
  end

  # ── tokenizer ────────────────────────────────────────────────────────────

  defp tokenize(tex), do: tokenize(String.graphemes(tex), [])

  defp tokenize([], acc), do: Enum.reverse(acc)

  defp tokenize([c | rest], acc) when c in [" ", "\t", "\n"], do: tokenize(rest, acc)

  defp tokenize(["\\" | rest], acc) do
    {name, remainder} = Enum.split_while(rest, &letter?/1)

    if name == [] do
      tokenize(rest, [{:char, "\\"} | acc])
    else
      tokenize(remainder, [{:macro, "\\" <> Enum.join(name)} | acc])
    end
  end

  defp tokenize(["{" | rest], acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize(["}" | rest], acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize(["^" | rest], acc), do: tokenize(rest, [:caret | acc])
  defp tokenize(["_" | rest], acc), do: tokenize(rest, [:underscore | acc])
  defp tokenize([c | rest], acc), do: tokenize(rest, [{:char, c} | acc])

  defp letter?(c), do: c =~ ~r/^[a-zA-Z]$/

  # ── recursive-descent parser (bounded: groups, macros, digit runs, scripts) ─

  # parse_row/1 reads atoms until a closing brace or end of input, attaching
  # any immediately-following ^/_ as an msup/msub/msubsup wrapper around the
  # base — returns {html, remaining_tokens}.
  defp parse_row(tokens), do: parse_row(tokens, "")

  defp parse_row([], acc), do: {acc, []}
  defp parse_row([:rbrace | _] = tokens, acc), do: {acc, tokens}

  defp parse_row(tokens, acc) do
    {base, rest} = parse_atom(tokens)
    {base, rest} = attach_scripts(base, rest)
    parse_row(rest, acc <> base)
  end

  defp attach_scripts(base, [:caret | rest]) do
    {sup, rest2} = parse_group(rest)

    case rest2 do
      [:underscore | rest3] ->
        {sub, rest4} = parse_group(rest3)
        {~s|<msubsup><mrow>#{base}</mrow><mrow>#{sub}</mrow><mrow>#{sup}</mrow></msubsup>|, rest4}

      _ ->
        {~s|<msup><mrow>#{base}</mrow><mrow>#{sup}</mrow></msup>|, rest2}
    end
  end

  defp attach_scripts(base, [:underscore | rest]) do
    {sub, rest2} = parse_group(rest)

    case rest2 do
      [:caret | rest3] ->
        {sup, rest4} = parse_group(rest3)
        {~s|<msubsup><mrow>#{base}</mrow><mrow>#{sub}</mrow><mrow>#{sup}</mrow></msubsup>|, rest4}

      _ ->
        {~s|<msub><mrow>#{base}</mrow><mrow>#{sub}</mrow></msub>|, rest2}
    end
  end

  defp attach_scripts(base, rest), do: {base, rest}

  # A `{...}` group, or (TeX's own tolerance) a single bare atom.
  defp parse_group([:lbrace | rest]) do
    {inner, rest2} = parse_row(rest)

    case rest2 do
      [:rbrace | rest3] -> {inner, rest3}
      _ -> {inner, rest2}
    end
  end

  defp parse_group(tokens), do: parse_atom(tokens)

  defp parse_atom([]), do: {"", []}

  defp parse_atom([:lbrace | rest]) do
    {inner, rest2} = parse_row(rest)

    case rest2 do
      [:rbrace | rest3] -> {~s|<mrow>#{inner}</mrow>|, rest3}
      _ -> {~s|<mrow>#{inner}</mrow>|, rest2}
    end
  end

  defp parse_atom([{:macro, "\\frac"} | rest]) do
    {num, rest2} = parse_group(rest)
    {den, rest3} = parse_group(rest2)
    {~s|<mfrac><mrow>#{num}</mrow><mrow>#{den}</mrow></mfrac>|, rest3}
  end

  defp parse_atom([{:macro, name} | rest]) do
    case Map.get(@macros, name) do
      nil -> {~s|<mtext>#{Util.escape_html(name)}</mtext>|, rest}
      sym -> {~s|<mi>#{Util.escape_html(sym)}</mi>|, rest}
    end
  end

  defp parse_atom([{:char, c} | rest]) do
    if c =~ ~r/^[0-9]$/ do
      {digits, rest2} = Enum.split_while(rest, &digit_char?/1)
      value = Enum.join([c | Enum.map(digits, fn {:char, d} -> d end)])
      {~s|<mn>#{Util.escape_html(value)}</mn>|, rest2}
    else
      if MapSet.member?(@operators, c),
        do: {~s|<mo>#{Util.escape_html(c)}</mo>|, rest},
        else: {~s|<mi>#{Util.escape_html(c)}</mi>|, rest}
    end
  end

  # A stray caret/underscore/rbrace with nothing to bind to — consume it so
  # the parser always makes progress.
  defp parse_atom([_ | rest]), do: {"", rest}

  defp digit_char?({:char, c}), do: c =~ ~r/^[0-9.]$/
  defp digit_char?(_), do: false

  defp stringish(s) when is_binary(s), do: s
  defp stringish(n) when is_integer(n) or is_float(n), do: to_string(n)
  defp stringish(nil), do: ""
  defp stringish(other), do: to_string(other)
end
