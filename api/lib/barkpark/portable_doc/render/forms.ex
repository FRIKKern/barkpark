defmodule Barkpark.PortableDoc.Render.Forms do
  @moduledoc """
  Render-only grill / questionnaire (`form` block) HTML emission for the
  PortableDoc render engine.

  A render-only grill / questionnaire: one `<fieldset>` per question, clean
  semantic controls per the grill.js input types. No `<script>`, no
  action/method, no submit wiring. Every user string is escape_html'd. The
  container class (`bp-form bp-form-<kind>`) lets the host CSS hook in; the
  `kind` discriminator defaults to "grill". Article mode adds a couple of
  inline style cues (muted lines, spacing); email mode is the plainer twin.
  Both are deterministic.

  Extracted verbatim from `Barkpark.PortableDoc.Render` (module location only —
  NO logic change). Output is byte-identical to the pre-split engine.
  """

  import Barkpark.PortableDoc.Render.Util, only: [escape_html: 1, escape_attr: 1]

  def form_html(b, style) do
    kind = b |> Map.get("kind", "grill") |> to_string()
    kind_class = if kind == "questionnaire", do: "bp-form-questionnaire", else: "bp-form-grill"

    questions =
      b
      |> Map.get("questions", [])
      |> List.wrap()
      |> Enum.map(&form_question_html(&1, style))
      |> Enum.join("")

    ~s(<section class="bp-form #{kind_class}">) <> questions <> "</section>"
  end

  defp form_question_html(q, style) when is_map(q) do
    id = q |> Map.get("id", "") |> to_string()
    prompt = q |> Map.get("prompt", "") |> to_string()
    type = q |> Map.get("type", "text") |> to_string()

    legend = ~s(<legend>#{escape_html(prompt)}</legend>)

    rationale_line = form_muted_line(Map.get(q, "rationale"), "", style)
    recommendation_line = form_muted_line(Map.get(q, "recommendation"), "Recommendation: ", style)

    control = form_control_html(type, id, q, style)

    ~s(<fieldset class="bp-form-question">) <>
      legend <> rationale_line <> recommendation_line <> control <> "</fieldset>"
  end

  defp form_question_html(_q, _style), do: ""

  # A muted context/recommendation paragraph; rendered only when text present.
  defp form_muted_line(nil, _prefix, _style), do: ""
  defp form_muted_line("", _prefix, _style), do: ""

  defp form_muted_line(text, prefix, style) when is_binary(text) do
    color = if style == :article, do: "#6a6a6a", else: "#6b7280"

    ~s(<p style="color:#{color};font-size:0.9em;margin:0.3rem 0">#{escape_html(prefix)}#{escape_html(text)}</p>)
  end

  defp form_muted_line(text, prefix, style), do: form_muted_line(to_string(text), prefix, style)

  # Per-type control markup. All names share the question id so grouped
  # radios/checkboxes round-trip to one answer field at the interactive phase.
  defp form_control_html("yesno", id, _q, style) do
    form_radio_group(id, ["Yes", "No"], style)
  end

  defp form_control_html("single", id, q, style) do
    options = q |> Map.get("options", []) |> List.wrap() |> Enum.map(&to_string/1)
    form_radio_group(id, options, style)
  end

  defp form_control_html("multi", id, q, style) do
    options = q |> Map.get("options", []) |> List.wrap() |> Enum.map(&to_string/1)
    form_choice_group(id, options, "checkbox", style)
  end

  defp form_control_html("scale", id, q, style) do
    scale = Map.get(q, "scale", %{})
    min = scale_bound(Map.get(scale, "min"), 1)
    max = scale_bound(Map.get(scale, "max"), 5)
    labels = if max >= min, do: Enum.map(min..max, &Integer.to_string/1), else: []
    form_radio_group(id, labels, style)
  end

  defp form_control_html("text", id, _q, _style) do
    ~s(<textarea name="#{escape_attr(id)}" rows="3"></textarea>)
  end

  # Unknown type → degrade to a text control (render-only, never crash).
  defp form_control_html(_type, id, _q, _style) do
    ~s(<textarea name="#{escape_attr(id)}" rows="3"></textarea>)
  end

  defp form_radio_group(id, labels, style), do: form_choice_group(id, labels, "radio", style)

  defp form_choice_group(id, labels, input_type, style) do
    gap = if style == :article, do: "0.35rem", else: "0.2rem"

    labels
    |> Enum.map(fn label ->
      ~s(<label style="display:block;margin:#{gap} 0">) <>
        ~s(<input type="#{input_type}" name="#{escape_attr(id)}" value="#{escape_attr(label)}"> ) <>
        ~s(<span>#{escape_html(label)}</span></label>)
    end)
    |> Enum.join("")
  end

  # Coerce a scale bound to an integer, falling back to `default`.
  defp scale_bound(v, _default) when is_integer(v), do: v

  defp scale_bound(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp scale_bound(_v, default), do: default
end
