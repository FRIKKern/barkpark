# control-clean.ex — doc-truth code-comment acceptance CONTROL (correct citations
# ONLY). Every path citation resolves; every retired-term mention is negated or
# historical. The code-comment verifier AND retired-terms MUST emit ZERO findings
# here — it is the never-cry-wolf guarantee for the code-comment lane, the exact
# analogue of the js-tests.yml gate for the markdown lane. Not compiled (lives
# under fixtures/, outside api/lib) — it is fixture data, read as text.
defmodule DocTruth.ControlClean do
  @moduledoc """
  The Studio graph pane is a self-contained Canvas2D renderer now; Cytoscape was
  fully gutted and removed — this mention is historical and must NOT flag.

  The verifier entry point lives in `tooling/doc-truth/verify-docs.mjs`; the
  denylist in `tooling/doc-truth/retired-terms.mjs`. Both paths resolve.
  """
  def noop, do: :ok
end
