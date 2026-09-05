defmodule Barkpark.Content.Warnings do
  @moduledoc """
  The advisory channel of the publish wall (authoring-excellence D5) — a
  per-process accumulator for non-blocking `warnings` that ride the mutate
  SUCCESS envelope as `[{code, severity, message}]`.

  Born with the label-spine mount (ae-w1-publish-wall-mount); the tag-registry
  and dedup walls (S3/S4) extend it with their advise-band entries. An advisory
  NEVER blocks a write and is never promoted to an error — that split is a
  ratified epic decision (charter D5), not a default.

  Mechanics mirror `Content.Broadcast`'s deferred-broadcast queue: the emitters
  (deep inside `Lifecycle.publish_document`) run in the SAME process as the
  controller action and the surrounding `Repo.transaction`, so a process-dict
  queue is race-free. `MutateController` resets the queue before applying a
  batch and drains it into the success body afterwards; error responses drop
  the queue (a failed batch rolled back — its advisories describe writes that
  did not happen).
  """

  @key :barkpark_authoring_warnings

  @typedoc "One advisory entry — code + severity are stable machine keys."
  @type entry :: %{code: String.t(), severity: String.t(), message: String.t()}

  @doc "Reset the accumulator for a fresh request/batch."
  @spec reset() :: :ok
  def reset do
    Process.put(@key, [])
    :ok
  end

  @doc """
  Queue one advisory entry. Collect-only-when-listening: entries are dropped
  unless a collector opened the queue with `reset/0` first — so a long-lived
  process that publishes without draining (a Studio LiveView calling
  `Content.publish_document` directly) can never grow an unbounded queue.
  Emitters call this unconditionally and never need to know whether a
  controller is listening.

  Severity defaults to `"advisory"` (the tag-count norm); an emitter with a
  sharper signal passes its own — the E4 dedup wall's advise band stamps
  `"warning"`. Never an error: promotion is charter-forbidden (D5).
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(code, message, severity \\ "advisory")
      when is_binary(code) and is_binary(message) and is_binary(severity) do
    case Process.get(@key) do
      nil ->
        :ok

      entries when is_list(entries) ->
        entry = %{code: code, severity: severity, message: message}
        Process.put(@key, [entry | entries])
        :ok
    end
  end

  @doc """
  Whether a collector opened the queue with `reset/0`. Emitters that must pay
  for a DB read to decide whether they have anything to say check this first —
  `put/3` already drops silently when nobody listens, but it cannot refund the
  read that computed the message.
  """
  @spec listening?() :: boolean()
  def listening?, do: is_list(Process.get(@key))

  @doc "Drain the queued entries in emission order and clear the accumulator."
  @spec drain() :: [entry()]
  def drain do
    entries = Process.get(@key, [])
    Process.put(@key, [])
    Enum.reverse(entries)
  end
end
