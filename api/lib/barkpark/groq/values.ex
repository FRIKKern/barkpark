defmodule Barkpark.Groq.Values do
  @moduledoc """
  GROQ value semantics: types, equality, partial and total ordering, arithmetic,
  and the conversion of evaluated values to JSON.

  A value is plain decoded JSON (`nil`, booleans, numbers, binaries, lists,
  maps) or one of two internal kinds that only functions produce:
  `{:datetime, DateTime.t()}` from `dateTime()` and `{:path, pattern, regex}`
  from `path()`. `to_json/1` turns both back into strings.

  Numbers follow JavaScript doubles, as groq-js does: an integral float such as
  `2.0` is the number `2`, and a non-finite result is `null`.
  """

  @type t :: term()

  @max_safe 9_007_199_254_740_991

  @spec type_of(t()) :: atom()
  def type_of(nil), do: :null
  def type_of(v) when is_boolean(v), do: :boolean
  def type_of(v) when is_number(v), do: :number
  def type_of(v) when is_binary(v), do: :string
  def type_of(v) when is_list(v), do: :array
  def type_of(v) when is_map(v), do: :object
  def type_of({:datetime, _}), do: :datetime
  def type_of({:path, _, _}), do: :path
  def type_of(_), do: :null

  @doc "Normalizes a number the way a JavaScript double would read back."
  @spec num(number()) :: number() | nil
  def num(n) when is_integer(n) do
    if abs(n) <= @max_safe, do: n, else: to_double(n)
  end

  def num(f) when is_float(f) do
    if abs(f) <= @max_safe and f == trunc(f), do: trunc(f), else: f
  end

  # An integer beyond the double range is Infinity in JavaScript, which GROQ
  # turns into null.
  defp to_double(n) do
    n * 1.0
  rescue
    ArithmeticError -> nil
  end

  @doc "GROQ `==`: only booleans, null, numbers, strings and datetimes compare."
  @spec equal?(t(), t()) :: boolean()
  def equal?(nil, nil), do: true
  def equal?(a, b) when is_boolean(a) and is_boolean(b), do: a == b
  def equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def equal?(a, b) when is_binary(a) and is_binary(b), do: a == b
  def equal?({:datetime, a}, {:datetime, b}), do: DateTime.compare(a, b) == :eq
  def equal?(_, _), do: false

  @doc "Partial comparison: `nil` when the two values do not order."
  @spec partial_compare(t(), t()) :: -1 | 0 | 1 | nil
  def partial_compare(a, b) when is_number(a) and is_number(b), do: cmp(a, b)

  def partial_compare(a, b) when is_boolean(a) and is_boolean(b),
    do: cmp(bool_rank(a), bool_rank(b))

  def partial_compare(a, b) when is_binary(a) and is_binary(b), do: cmp_string(a, b)

  def partial_compare({:datetime, a}, {:datetime, b}) do
    case DateTime.compare(a, b) do
      :lt -> -1
      :eq -> 0
      :gt -> 1
    end
  end

  def partial_compare(_, _), do: nil

  @type_order %{datetime: 1, number: 2, string: 3, boolean: 4}

  @doc "Total ordering used by `order()`: datetime < number < string < boolean < rest."
  @spec total_compare(t(), t()) :: -1 | 0 | 1
  def total_compare(a, b) do
    ra = Map.get(@type_order, type_of(a), 100)
    rb = Map.get(@type_order, type_of(b), 100)

    if ra != rb do
      cmp(ra, rb)
    else
      partial_compare(a, b) || 0
    end
  end

  defp bool_rank(true), do: 1
  defp bool_rank(false), do: 0

  defp cmp(a, b) when a < b, do: -1
  defp cmp(a, b) when a > b, do: 1
  defp cmp(_, _), do: 0

  # JavaScript compares strings by UTF-16 code unit. Byte order of UTF-8 equals
  # code point order, which differs only for characters above U+FFFF against
  # U+E000..U+FFFF; those are compared through UTF-16 to stay exact.
  defp cmp_string(a, b) when a == b, do: 0

  defp cmp_string(a, b) do
    if ascii_or_bmp_safe?(a) and ascii_or_bmp_safe?(b) do
      cmp(a, b)
    else
      cmp(
        :unicode.characters_to_binary(a, :utf8, :utf16),
        :unicode.characters_to_binary(b, :utf8, :utf16)
      )
    end
  end

  # True when the string holds no 4-byte UTF-8 sequence (no astral characters).
  defp ascii_or_bmp_safe?(s), do: not String.match?(s, ~r/[\x{10000}-\x{10FFFF}]/u)

  @doc "Binary arithmetic for `+ - * / % **` (groq-js evaluator/operators.ts)."
  @spec arith(String.t(), t(), t()) :: t()
  def arith("+", {:datetime, dt}, n) when is_number(n), do: add_seconds(dt, n)
  def arith("+", n, {:datetime, dt}) when is_number(n), do: add_seconds(dt, n)
  def arith("+", a, b) when is_number(a) and is_number(b), do: finite(a + b)
  def arith("+", a, b) when is_binary(a) and is_binary(b), do: a <> b
  def arith("+", a, b) when is_map(a) and is_map(b), do: Map.merge(a, b)
  def arith("+", a, b) when is_list(a) and is_list(b), do: a ++ b
  def arith("-", {:datetime, dt}, n) when is_number(n), do: add_seconds(dt, -n)

  def arith("-", {:datetime, a}, {:datetime, b}),
    do: num(DateTime.diff(a, b, :microsecond) / 1_000_000)

  def arith("-", a, b) when is_number(a) and is_number(b), do: finite(a - b)
  def arith("*", a, b) when is_number(a) and is_number(b), do: finite(a * b)

  def arith("/", a, b) when is_number(a) and is_number(b) do
    if b == 0, do: nil, else: finite(a / b)
  end

  def arith("%", a, b) when is_integer(a) and is_integer(b) do
    if b == 0, do: nil, else: num(rem(a, b))
  end

  def arith("%", a, b) when is_number(a) and is_number(b) do
    if b == 0, do: nil, else: finite(:math.fmod(a * 1.0, b * 1.0))
  end

  def arith("**", a, b) when is_integer(a) and is_integer(b) and b >= 0 and b < 1024 do
    finite(Integer.pow(a, b))
  end

  def arith("**", a, b) when is_number(a) and is_number(b) do
    finite(:math.pow(a * 1.0, b * 1.0))
  rescue
    ArithmeticError -> nil
  end

  def arith(_op, _a, _b), do: nil

  defp finite(n) when is_integer(n), do: num(n)

  defp finite(f) when is_float(f), do: num(f)

  defp add_seconds(dt, secs) do
    {:datetime, DateTime.add(dt, round(secs * 1_000_000), :microsecond)}
  end

  @doc "Parses an RFC 3339 timestamp the way groq-js `parseRFC3339` does."
  @spec parse_datetime(String.t()) :: {:datetime, DateTime.t()} | nil
  def parse_datetime(str) when is_binary(str) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|([-+]\d{2}:\d{2}))$/, str) do
      case DateTime.from_iso8601(str) do
        {:ok, dt, _offset} -> {:datetime, truncate_millis(dt)}
        _ -> nil
      end
    end
  end

  def parse_datetime(_), do: nil

  # JavaScript Date keeps milliseconds only.
  defp truncate_millis(dt), do: DateTime.truncate(dt, :millisecond)

  @doc "Formats a datetime as groq-js does: UTC, milliseconds only when non-zero."
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")
    {micro, _} = dt.microsecond
    millis = div(micro, 1000)
    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")

    if millis == 0,
      do: base <> "Z",
      else: base <> "." <> String.pad_leading(Integer.to_string(millis), 3, "0") <> "Z"
  end

  @doc "Converts an evaluated value to plain JSON-encodable data."
  @spec to_json(t()) :: term()
  def to_json(nil), do: nil
  def to_json(v) when is_boolean(v) or is_binary(v), do: v
  def to_json(v) when is_number(v), do: num(v)
  def to_json(v) when is_list(v), do: Enum.map(v, &to_json/1)
  def to_json(v) when is_map(v), do: Map.new(v, fn {k, x} -> {k, to_json(x)} end)
  def to_json({:datetime, dt}), do: format_datetime(dt)
  def to_json({:path, pattern, _}), do: pattern
  def to_json(_), do: nil

  @doc "The string form `string()` and `array::join` use, or `:error`."
  @spec stringify(t()) :: {:ok, String.t()} | :error
  def stringify(v) when is_binary(v), do: {:ok, v}
  def stringify(true), do: {:ok, "true"}
  def stringify(false), do: {:ok, "false"}
  def stringify(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  def stringify(v) when is_float(v), do: {:ok, format_float(v)}
  def stringify({:datetime, dt}), do: {:ok, format_datetime(dt)}
  def stringify(_), do: :error

  # JavaScript's Number#toString: integral floats print without a fraction,
  # small/large magnitudes switch to exponent notation.
  defp format_float(f) do
    case num(f) do
      i when is_integer(i) ->
        Integer.to_string(i)

      _ ->
        abs = abs(f)

        if abs >= 1.0e21 or abs < 1.0e-6 do
          js_exponent(f)
        else
          :erlang.float_to_binary(f, [:short])
        end
    end
  end

  defp js_exponent(f) do
    [mantissa, exp] = String.split(:erlang.float_to_binary(f, [:short]), "e")
    mantissa = String.replace_suffix(mantissa, ".0", "")
    exp_int = String.to_integer(exp)
    sign = if exp_int >= 0, do: "+", else: "-"
    "#{mantissa}e#{sign}#{abs(exp_int)}"
  end
end
