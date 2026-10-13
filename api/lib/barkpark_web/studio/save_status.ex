defmodule BarkparkWeb.Studio.SaveStatus do
  @moduledoc """
  The words a Studio editor's save region shows for the server's save tokens.

  The socket holds a token ("Saved", "Save failed", …); the Classic editor and
  the paper footer both show it through `label/1`, so an nb Studio reads
  "Lagret" in either (task-42df0e13a6a35ff3). The calm "Auto-saved" keeps its
  ✓ affix. Any other server text is echoed verbatim, so the region can never
  hide a failed or vetoed write behind a friendlier word.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  @spec label(term()) :: String.t()
  def label("Auto-saved"), do: gettext("✓ Auto-saved")
  def label("Save failed"), do: gettext("Save failed")
  def label("Saved"), do: gettext("Saved")
  def label("Save cancelled"), do: gettext("Save cancelled")
  def label("Read-only"), do: gettext("Read-only")
  def label("Updated by another user"), do: gettext("Updated by another user")
  def label(status) when is_binary(status), do: status
  def label(_), do: ""
end
