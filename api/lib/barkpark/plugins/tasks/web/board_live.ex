defmodule Barkpark.Plugins.Tasks.Web.BoardLive do
  @moduledoc """
  Barkpark Projects — the native task BOARD, read-only baseline (wave 1).

  A visual kanban over the REAL `type:task` documents (the source of truth),
  mounted in Studio at `/admin/projects` (the `:ops` bucket, admin-gated). It is
  the GUI realization of the task design-language spec
  (`.claude/workflows/bp-task-design-language-spec.md`) — the browser sibling of
  the `bp tasks` TUI board — and clones the pulse `DashboardLive` shape: a
  standalone plugin LiveView, `/admin/*` (not `/studio/*`, which the desk-link
  scoper mangles), owned by the tasks plugin because it owns `type:task`.

  ## Feels-alive baseline (charter §criterion, wave 1)

  Even with NO realtime yet (subscribe/drag/refresh land in later waves), the
  board must FEEL ALIVE the instant it paints:

    * a **momentum header** — `◐ N in flight · ○ N ready · ✓ N done today · NN%`
      with an animated fill bar (CSS width transition) — is the always-on
      progress read;
    * the **Ready column** is the visible always-a-next-step;
    * the in_progress cards **breathe at rest** via a PURE-CSS Braille spinner
      (`@keyframes` cycling a `.gi--in_progress::before` through the 10 TUI
      frames ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ at ~80ms/frame) — zero JS, CSP-safe, and it works in a
      static render. `prefers-reduced-motion` freezes it on `⠿`.

  The glyph/color vocabulary is the §1 manifest VERBATIM — the identical Unicode
  character the TUI paints (never a lookalike SVG) — supplied by
  `Barkpark.Tasks.Board` (`glyph`/`color_role` per card) and dressed with the
  §1 light/dark hexes in the inline `<style>` block below.

  ## GitHub badge (charter D7)

  Each card whose `content.github` mirror is present (stamped by the just-shipped
  GitHub bridge) carries a badge — the mirror-issue `#number`, a sync dot
  (synced/detached), and a click-through to `github.com/<repo>/issues/<n>`. A
  card with no mirror renders NO badge — never fabricated. This is a pure
  `content.github` read attached in the organizer's card projection, safe even
  with the github plugin dark.

  Purely observational — no writes, no controls. `mount/3` assigns the snapshot;
  there is deliberately no subscribe/refresh/drag in this slice.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Tasks.Board

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :board, Board.snapshot(dataset: "production"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Barkpark Projects board — §1/§2 task design-language vocabulary.
         Self-contained + CSP-safe (pulse's inline discipline). Curly braces
         inside <style> are verbatim in HEEx 1.x — no interpolation here. */
      .bp-board-wrap { max-width: 82rem; }
      .bp-momentum {
        display: flex; align-items: center; gap: 1.4rem; flex-wrap: wrap;
        font-variant-numeric: tabular-nums; margin: 0.4rem 0 0.2rem;
        font-size: 1.05rem;
      }
      .bp-momentum .m-pct { font-weight: 700; margin-left: auto; }
      .bp-bar {
        height: 8px; border-radius: 999px; margin: 0.6rem 0 1.4rem;
        background: var(--muted-border-color, rgba(127,127,127,0.22));
        overflow: hidden;
      }
      .bp-bar-fill {
        height: 100%; border-radius: 999px;
        background: linear-gradient(90deg, #2563eb, #0d9488);
        transition: width 900ms cubic-bezier(0.22, 1, 0.36, 1);
      }

      .bp-board {
        display: grid;
        grid-template-columns: repeat(5, minmax(0, 1fr));
        gap: 0.9rem; align-items: start;
      }
      @media (max-width: 60rem) { .bp-board { grid-template-columns: 1fr; } }
      .bp-col { min-width: 0; }
      .bp-col-h {
        display: flex; align-items: baseline; gap: 0.5rem;
        font-size: 0.78rem; letter-spacing: 0.06em; text-transform: uppercase;
        opacity: 0.6; margin: 0 0 0.6rem; font-weight: 600;
      }
      .bp-col-n { opacity: 0.7; font-variant-numeric: tabular-nums; }
      .bp-col-empty { opacity: 0.35; font-size: 0.85rem; padding: 0.3rem 0; }

      .bp-card {
        border: 1px solid var(--muted-border-color, rgba(127,127,127,0.28));
        border-radius: 10px; padding: 0.6rem 0.7rem; margin: 0 0 0.6rem;
        background: var(--card-background-color, rgba(127,127,127,0.04));
      }
      .bp-card--done { opacity: 0.62; }
      .bp-card-top { display: flex; align-items: flex-start; gap: 0.5rem; }
      .bp-title { font-weight: 600; font-size: 0.92rem; line-height: 1.3; }
      .bp-meta {
        display: flex; flex-wrap: wrap; gap: 0.4rem 0.55rem;
        margin-top: 0.5rem; font-size: 0.74rem; align-items: center;
      }
      .bp-pip {
        font-variant-numeric: tabular-nums; font-weight: 700;
        padding: 0.02rem 0.32rem; border-radius: 5px;
        background: rgba(127,127,127,0.14);
      }
      .bp-goal {
        opacity: 0.85; padding: 0.02rem 0.32rem; border-radius: 5px;
        background: rgba(37,99,235,0.12);
      }
      .bp-goal::before { content: "↳ "; opacity: 0.7; }
      .bp-label {
        opacity: 0.7; padding: 0.02rem 0.3rem; border-radius: 5px;
        background: rgba(127,127,127,0.10);
      }
      .bp-worker { opacity: 0.8; }
      .bp-worker::before { content: "@"; opacity: 0.6; }
      .bp-crit {
        font-variant-numeric: tabular-nums; opacity: 0.85;
        padding: 0.02rem 0.3rem; border-radius: 5px;
        background: rgba(13,148,136,0.12);
      }

      /* ── §1 white-ladder glyph vocabulary ────────────────────────────── */
      .gi {
        display: inline-block; width: 1.1em; text-align: center;
        font-family: var(--font-mono, monospace); line-height: 1.3;
      }
      .gi--open { color: currentColor; opacity: 0.5; }      /* backlog: dim ○ */
      .gi--ready { color: currentColor; opacity: 1; }       /* unchecked: bright ○ */
      .gi--blocked { color: #d97706; font-weight: 700; }    /* amber ! */
      .gi--done { color: #0d9488; }                          /* teal ✓ */
      .gi--cancelled { color: #a1a1aa; }

      /* in_progress: pure-CSS Braille spinner, TUI-identical 10 frames,
         ~80ms/frame (800ms cycle). The glyph is supplied entirely by ::before
         so the frame-cycle needs no JS and survives a static render. */
      .gi--in_progress { color: #2563eb; }
      .gi--in_progress::before { content: "⠋"; animation: bp-braille 800ms steps(1) infinite; }
      @keyframes bp-braille {
        0%   { content: "⠋"; }
        10%  { content: "⠙"; }
        20%  { content: "⠹"; }
        30%  { content: "⠸"; }
        40%  { content: "⠼"; }
        50%  { content: "⠴"; }
        60%  { content: "⠦"; }
        70%  { content: "⠧"; }
        80%  { content: "⠇"; }
        90%  { content: "⠏"; }
      }

      /* GitHub badge — issue # + sync dot + click-through. */
      .bp-gh {
        display: inline-flex; align-items: center; gap: 0.28rem;
        text-decoration: none; font-variant-numeric: tabular-nums;
        padding: 0.02rem 0.34rem; border-radius: 5px; opacity: 0.9;
        border: 1px solid var(--muted-border-color, rgba(127,127,127,0.3));
      }
      .bp-gh:hover { opacity: 1; }
      .bp-gh-dot { width: 7px; height: 7px; border-radius: 999px; display: inline-block; }
      .bp-gh-dot.is-synced { background: #2dd4bf; }
      .bp-gh-dot.is-detached { background: #d97706; }
      .bp-gh-state { opacity: 0.6; }
      .bp-cancelled {
        margin: 1.2rem 0 0; opacity: 0.5; font-size: 0.85rem;
        color: #a1a1aa; font-variant-numeric: tabular-nums;
      }

      /* Dark-scheme §1 hexes (lighter, higher-contrast on dark surfaces). */
      @media (prefers-color-scheme: dark) {
        .gi--blocked { color: #fbbf24; }
        .gi--done { color: #2dd4bf; }
        .gi--cancelled, .bp-cancelled { color: #71717a; }
        .gi--in_progress { color: #60a5fa; }
      }

      /* Motion is a signal, not decoration — honor the reader's preference. */
      @media (prefers-reduced-motion: reduce) {
        .gi--in_progress::before { animation: none; content: "⠿"; }
        .bp-bar-fill { transition: none; }
      }
    </style>

    <main class="container bp-board-wrap">
      <h1>▦ Projects</h1>
      <p>
        <small>
          A live board over the real task documents. Columns are the status
          ladder; drag &amp; realtime land in later waves. Read-only for now.
        </small>
      </p>

      <header class="bp-momentum" data-role="momentum">
        <span data-role="m-inflight">◐ <%= @board.momentum.in_flight %> in flight</span>
        <span data-role="m-ready">○ <%= @board.momentum.ready %> ready</span>
        <span data-role="m-done-today">✓ <%= @board.momentum.done_today %> done today</span>
        <span class="m-pct" data-role="m-pct"><%= @board.momentum.pct %>%</span>
      </header>
      <div class="bp-bar" data-role="momentum-bar">
        <div class="bp-bar-fill" style={"width: #{@board.momentum.pct}%;"}></div>
      </div>

      <div :if={empty_board?(@board)} data-role="board-empty">
        <p><em>No tasks yet — file one with <code>bp task create</code> and it appears here.</em></p>
      </div>

      <div class="bp-board" data-role="board">
        <section :for={col <- Board.columns()} class="bp-col" data-role="column" data-col={col}>
          <h2 class="bp-col-h">
            <%= col_label(col) %>
            <span class="bp-col-n" data-role="col-count"><%= length(@board.columns[col]) %></span>
          </h2>

          <p :if={@board.columns[col] == []} class="bp-col-empty" data-role="col-empty">—</p>

          <article
            :for={card <- @board.columns[col]}
            class={"bp-card bp-card--#{col}"}
            data-role="task-card"
            data-col={col}
            data-doc-id={card.doc_id}
          >
            <div class="bp-card-top">
              <span
                class={"gi gi--#{card.color_role}"}
                data-role="glyph"
                data-status={card.lifecycle_status}
                aria-hidden="true"
              >
                <%= glyph_text(card) %>
              </span>
              <span class="bp-title" data-role="card-title"><%= card.title %></span>
            </div>

            <div class="bp-meta">
              <span :if={card.priority} class="bp-pip" data-role="priority" data-priority={card.priority}>
                P<%= card.priority %>
              </span>
              <span :if={card.parent_id} class="bp-goal" data-role="goal"><%= card.parent_id %></span>
              <span :for={label <- card.labels} class="bp-label" data-role="label"><%= label %></span>
              <span :if={card.worker} class="bp-worker" data-role="worker"><%= card.worker %></span>
              <span :if={card.criteria} class="bp-crit" data-role="criteria">
                <%= card.criteria.met %>/<%= card.criteria.total %>
              </span>

              <a
                :if={github_badge?(card.github)}
                class="bp-gh"
                data-role="github-badge"
                data-issue={card.github["issue"]}
                href={gh_href(card.github)}
                target="_blank"
                rel="noopener"
              >
                <span
                  class={"bp-gh-dot " <> if(github_synced?(card), do: "is-synced", else: "is-detached")}
                  data-role="github-dot"
                >
                </span>
                #<%= card.github["issue"] %>
                <span class="bp-gh-state" data-role="github-state"><%= card.github["state"] %></span>
              </a>
            </div>
          </article>
        </section>
      </div>

      <p :if={@board.cancelled_count > 0} class="bp-cancelled" data-role="cancelled-tally">
        ✕ <%= @board.cancelled_count %> cancelled
      </p>
    </main>
    """
  end

  # ── Render helpers ──────────────────────────────────────────────────────────

  defp col_label(:open), do: "Open"
  defp col_label(:ready), do: "Ready"
  defp col_label(:in_progress), do: "In Progress"
  defp col_label(:blocked), do: "Blocked"
  defp col_label(:done), do: "Done"

  # in_progress renders its (animated) glyph entirely from CSS `::before`, so the
  # span body is empty — every other state prints the literal §1 Unicode char.
  defp glyph_text(%{color_role: :in_progress}), do: ""
  defp glyph_text(%{glyph: glyph}), do: glyph

  defp gh_href(%{"repo" => repo, "issue" => issue})
       when is_binary(repo) and (is_integer(issue) or is_binary(issue)),
       do: "https://github.com/#{repo}/issues/#{issue}"

  defp gh_href(_), do: "#"

  # A badge is shown only when the mirror carries an actual issue number — the
  # moduledoc/D7 promise is "the mirror-issue #number", so a partial `github`
  # stamp with no `issue` (e.g. a bare `%{"state" => "detached"}`) renders NO
  # badge rather than a fabricated `#`-with-no-number and a dead `#` link.
  defp github_badge?(%{"issue" => issue}) when not is_nil(issue), do: true
  defp github_badge?(_), do: false

  # The sync dot. `github_synced` is the organizer's derived `synced_rev == rev`
  # flag; read it via Access (never a dot-access KeyError) so a card projection
  # that omits the field degrades to the conservative "detached" dot instead of
  # crashing the whole board render.
  defp github_synced?(card), do: card[:github_synced] == true

  defp empty_board?(board) do
    board.cancelled_count == 0 and
      Enum.all?(Board.columns(), fn col -> board.columns[col] == [] end)
  end
end
