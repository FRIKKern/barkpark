defmodule Barkpark.Content.TextUndo do
  @moduledoc """
  Takes one editor's own text change back out of a field, keeping what
  other editors wrote since (task-c25c112913859b11), as the TanStack
  Studio's undo (`app/src/lib/merge.ts`, `revert` and `revertSteps`).

  A change is a list of steps, each the text one save of this editor went
  from and the text it posted (`{from, to}`). Undo walks the steps from the
  last back, each one `to -> from`; redo walks them in order, `from -> to`.
  A step is placed on the text the store holds now with
  `TextRebase.merge3_both/3`: when someone else wrote elsewhere in the text,
  their words stay. A step whose words someone else wrote into or over no
  longer comes out cleanly, and then the whole change is left as it is:
  taking back half of it left a stray letter in the TanStack Studio.
  """

  alias Barkpark.Content.TextRebase

  @doc """
  The text `now` with the steps applied, each `{from, to}` turning its `from`
  back into its `to`, in order. `now` itself when any step does not apply.
  """
  @spec revert_steps([{String.t(), String.t()}], String.t()) :: String.t()
  def revert_steps(steps, now) when is_list(steps) and is_binary(now) do
    Enum.reduce_while(steps, now, fn {from, to}, text ->
      next = revert(from, to, text)
      if from != to and next == text, do: {:halt, now}, else: {:cont, next}
    end)
  end

  @doc """
  One step, `from -> to`, on `now`. It applies only when doing the step
  again on the result gives `now` back, so the splice found this editor's
  words and not someone else's. `now` when it does not apply.
  """
  @spec revert(String.t(), String.t(), String.t()) :: String.t()
  def revert(from, to, now) when is_binary(from) and is_binary(to) and is_binary(now) do
    with false <- now == from,
         back when is_binary(back) <- TextRebase.merge3_both(from, to, now),
         ^now <- TextRebase.merge3_both(to, from, back) do
      back
    else
      true -> to
      _ -> now
    end
  end
end
