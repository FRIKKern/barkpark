defmodule Barkpark.StudioChat.PlanPapers do
  @moduledoc """
  Projects an APPROVED ExitPlanMode plan into a real, published Bulldocs Paper
  (charter D49 — "the plan grows up").

  We ARE the API app, so there is no HTTP hop and no ingest token: the plan
  markdown goes straight through `FromMarkdown.blocks/1` into
  `Content.upsert_paper/2` (with the audited `bypass_wall: true` — charter
  D23-b/D26: this fire-and-forget projection cannot retry a publish-wall
  rejection, and plan markdown has no label surface), SCOPE-LESS. A
  scope-less upsert resolves the seeded
  Default workspace/project (`resolve_write_scope([])`,
  content/papers/block_ops.ex:78-80) — the SAME tenant the public
  `/papers/:slug` reader serves — and publishes the row unconditionally
  (`status: "published"`, content/papers/block_ops.ex:209). So the plan
  radiates for free to the reader, the TUI, and `/v1/structure`.

  The slug is DETERMINISTIC — `chat-plan-<first 12 hex of
  sha256(session_id <> request_id)>` — and `upsert_paper` keys writes on
  `{dataset, slug}`, so re-approving the same plan UPDATES the same row and
  never duplicates. `paper_id == slug`; `paper_url == "/papers/" <> slug`.

  D7 stands: the plan markdown persisted in the plan row's metadata is the
  source of truth; this Paper is a downstream projection of it.
  """

  alias Barkpark.Content
  alias Barkpark.PortableDoc.FromMarkdown
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder

  @dataset "production"

  @doc """
  Project an ALLOWED plan approval into its Paper — the ONE owner of the D49
  side effect, shared by EVERY surface that can answer an ask: the flat
  `POST /v1/chat/sessions/:id/approval` transport (TUI, `bp`, any HTTP client)
  and the Studio LiveView, which delegates here.

  Everything the projection needs is SERVER-HELD, so this seam is socket-free
  and caller-shape-free: the decision, plus the plan row the Recorder already
  persisted (`role: "plan"`, `metadata.input["plan"]` — the D7 source of truth).
  A caller supplies only the two ids and the decision it just delivered.

  ## Contract — what publishes NOTHING (every case a silent `:ok` no-op)

    * a deny / keep-planning decision — a rejected plan stays chat ephemera
      (D49: "create on APPROVE only");
    * a needs-you row that is not a `plan` (an ordinary tool approval, an
      AskUserQuestion) — only ExitPlanMode rows have a document to grow into;
    * a `request_id` with no persisted needs-you row (a replayed/unknown ask);
    * a plan row whose `metadata.input["plan"]` is absent or not a binary — the
      transport is provider-neutral (D36) and a provider that shapes its
      ExitPlanMode ask differently must degrade to "no Paper", never to a crash
      or an empty one;
    * a plan whose markdown is blank once trimmed — an empty Paper is a worse
      artifact than no Paper.

  On a real publish the work runs as a supervised, FIRE-AND-FORGET task
  (`Barkpark.TaskSupervisor`, `$callers`-scoped so it inherits the sandbox
  connection under test and is drained on test exit): the approve has already
  hit the wire, and D49 is explicit that it must never block or fail on a
  publish error. The task never touches a socket or a conn — it stamps the row
  and broadcasts on the session topic every surface already listens to. Always
  returns `:ok`.
  """
  @spec publish_approved_plan(String.t(), String.t(), term()) :: :ok
  def publish_approved_plan(session_id, request_id, decision)
      when is_binary(session_id) and is_binary(request_id) do
    with true <- allow?(decision),
         %{role: "plan"} = row <- StudioChat.get_needs_you_message(session_id, request_id),
         markdown when is_binary(markdown) <- plan_markdown(row.metadata),
         false <- String.trim(markdown) == "" do
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        project(session_id, request_id, markdown)
      end)
    end

    :ok
  end

  # Both decision vocabularies mean the same thing here: the transport validates
  # to a bare `:allow` (D22 forbids caller-supplied updatedInput), while the
  # LiveView can carry an engine `{:allow, updated_input}`. Anything else — a
  # `{:deny, _}`, an unknown term — is not an approval.
  defp allow?(:allow), do: true
  defp allow?({:allow, _}), do: true
  defp allow?(_), do: false

  # The server-held plan markdown (D7). Anything but a binary under
  # `input["plan"]` is "no plan to publish", not a crash.
  defp plan_markdown(%{"input" => %{"plan" => plan}}) when is_binary(plan), do: plan
  defp plan_markdown(_), do: nil

  # The fire-and-forget body: publish the Paper, stamp its id/url onto the plan
  # row's metadata (replay-durable, D49), and broadcast the outcome on the
  # session topic so every co-viewing surface converges on the same link.
  defp project(session_id, request_id, markdown) do
    topic = Recorder.topic(session_id)

    # A RAISE inside publish (malformed markdown through FromMarkdown, an upsert
    # invariant) must degrade to the SAME honest failure broadcast as an
    # `{:error, _}` return — a crashed fire-and-forget task is silent, and the
    # promised "couldn't publish" line would never appear. Scoped to the publish
    # call only: a raise AFTER a successful publish must not lie "couldn't
    # publish" about a Paper that exists.
    result =
      try do
        publish(session_id, request_id, markdown)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, %{paper_id: paper_id, paper_url: paper_url}} ->
        StudioChat.merge_approval_metadata(session_id, request_id, %{
          "paper_id" => paper_id,
          "paper_url" => paper_url
        })

        Phoenix.PubSub.broadcast(
          Barkpark.PubSub,
          topic,
          {:plan_paper, request_id, %{paper_id: paper_id, paper_url: paper_url}}
        )

      {:error, _reason} ->
        Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:plan_paper_failed, request_id})
    end
  end

  @doc """
  Publish (or idempotently re-publish) the approved plan as a Paper.

  Returns `{:ok, %{paper_id: slug, paper_url: "/papers/<slug>"}}` on success, or
  `{:error, reason}` (a changeset or any raised term the upsert surfaces) — the
  caller (a fire-and-forget Task) must never let a failure block or fail the
  approve, so it broadcasts honestly on `{:error, _}` rather than raising.
  """
  @spec publish(String.t(), String.t(), String.t()) ::
          {:ok, %{paper_id: String.t(), paper_url: String.t()}} | {:error, term()}
  def publish(session_id, request_id, plan_markdown)
      when is_binary(session_id) and is_binary(request_id) and is_binary(plan_markdown) do
    slug = slug_for(session_id, request_id)

    case Content.upsert_paper(
           %{
             "slug" => slug,
             "blocks" => FromMarkdown.blocks(plan_markdown),
             "style" => "article",
             "dataset" => @dataset
           },
           # bypass_wall (charter D23-b/D26): this is a fire-and-forget internal
           # projection of an ALREADY-approved plan — the approve must never fail
           # or silently drop the paper on a wall 422, and plan markdown carries
           # no label surface to retry with. Explicit, audited exemption.
           bypass_wall: true
         ) do
      {:ok, _doc} -> {:ok, %{paper_id: slug, paper_url: paper_url(slug)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The deterministic paper slug for a plan (charter D49). Same `session_id +
  request_id` ⇒ same slug ⇒ same paper row, forever — that is what makes a
  re-approve idempotent by construction.
  """
  @spec slug_for(String.t(), String.t()) :: String.t()
  def slug_for(session_id, request_id)
      when is_binary(session_id) and is_binary(request_id) do
    digest =
      :crypto.hash(:sha256, session_id <> request_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "chat-plan-" <> digest
  end

  @doc "The reader URL for a plan slug — the same route `/papers/:slug` serves."
  @spec paper_url(String.t()) :: String.t()
  def paper_url(slug) when is_binary(slug), do: "/papers/#{slug}"
end
