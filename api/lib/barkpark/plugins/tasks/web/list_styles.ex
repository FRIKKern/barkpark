defmodule Barkpark.Plugins.Tasks.Web.ListStyles do
  @moduledoc """
  The Tasks list page's stylesheet (`Barkpark.Plugins.Tasks.Web.ListLive`).

  It uses the board's class names and the Studio tokens. The board's styles
  are inline in its own render, so this page states the few it uses. Themes
  flip on the root layout's tokens; nothing here names a colour.
  """

  use Phoenix.Component

  @doc "The inline `<style>` block for the list page."
  def styles(assigns) do
    ~H"""
    <style>
      .bp-page {
        flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column;
        padding: 20px clamp(16px, 2.5vw, 34px) 10px;
        font-family: var(--font, 'Inter', -apple-system, sans-serif);
        font-size: 13px; color: var(--text); -webkit-font-smoothing: antialiased;
      }
      .tl-page { overflow-y: auto; }
      .bp-head {
        display: flex; align-items: flex-end; justify-content: space-between;
        flex-wrap: wrap; gap: 12px 40px; margin: 2px 0 16px;
      }
      .bp-h1 { margin: 0; font-size: 20px; font-weight: 600; letter-spacing: -0.02em; line-height: 1.2; }
      .bp-sub { margin: 5px 0 0; font-size: 13px; color: var(--muted-text); }
      .tl-switch, .bp-chip {
        font: inherit; font-size: 12px; line-height: 1.2; padding: 3px 10px;
        border-radius: 999px; cursor: pointer; text-decoration: none;
        color: var(--muted-text); border: 1px solid var(--border); background: var(--surface);
      }
      .tl-switch:hover, .bp-chip:hover { border-color: var(--ring); color: var(--text); }
      .bp-chip.is-active { border-color: var(--primary); color: var(--primary-fg); background: var(--primary); }
      .tl-form { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 10px; }
      .tl-input {
        font: inherit; font-size: 13px; padding: 6px 10px; width: 150px;
        color: var(--text); background: var(--surface);
        border: 1px solid var(--border); border-radius: 8px;
      }
      .tl-input--q { flex: 1 1 260px; max-width: 420px; }
      .tl-input:focus-visible, .bp-chip:focus-visible, .tl-switch:focus-visible {
        outline: 2px solid var(--ring); outline-offset: 1px;
      }
      .tl-chips { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin: 0 0 14px; }
      .tl-sep { width: 1px; height: 16px; background: var(--border); margin: 0 4px; }
      .tl-count { margin-left: auto; color: var(--muted-text); font-variant-numeric: tabular-nums; }
      .tl-note { margin: 28px 0; color: var(--muted-text); font-size: 14px; }
      .tl-table { width: 100%; border-collapse: collapse; }
      .tl-table th {
        position: sticky; top: -20px; z-index: 1; background: var(--bg);
        text-align: left; font-size: 11px; font-weight: 600; letter-spacing: 0.07em;
        text-transform: uppercase; color: var(--muted-text);
        padding: 8px 10px; border-bottom: 1px solid var(--border); white-space: nowrap;
      }
      .tl-table td { padding: 8px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
      .tl-table tbody tr:hover { background: var(--muted-surface); }
      .tl-sort { color: inherit; text-decoration: none; }
      .tl-sort:hover, .tl-sort.is-active { color: var(--text); }
      .tl-title { min-width: 260px; }
      .tl-title a { color: var(--text); font-weight: 500; text-decoration: none; }
      .tl-title a:hover { text-decoration: underline; }
      .tl-id {
        display: block; margin-top: 2px; font-size: 11px; color: var(--muted-text);
        font-family: var(--font-mono, monospace);
      }
      .tl-nowrap { white-space: nowrap; }
      .tl-num { font-variant-numeric: tabular-nums; color: var(--muted-text); }
      .tl-quiet { color: var(--muted-text); text-decoration: none; }
      .tl-quiet:hover { color: var(--text); text-decoration: underline; }
      .bp-pip, .bp-goal, .bp-label {
        display: inline-block; padding: 1.5px 7px; border-radius: 5px; line-height: 1.5;
        font-size: 11px; white-space: nowrap; text-decoration: none; margin: 0 4px 3px 0;
      }
      .bp-pip { background: var(--muted-surface); color: var(--muted-text); font-weight: 600; }
      .bp-pip[data-priority="0"] { background: var(--danger-soft); color: var(--danger-text); }
      .bp-pip[data-priority="1"] { background: var(--warn-soft); color: var(--warn-text); }
      .bp-goal {
        background: var(--info-soft); color: var(--info-text);
        max-width: 26ch; overflow: hidden; text-overflow: ellipsis; vertical-align: bottom;
      }
      .bp-label { background: var(--muted-surface); color: var(--muted-text); }
      .gi {
        display: inline-block; width: 1.1em; text-align: center;
        font-family: var(--font-mono, monospace); line-height: 1.3;
      }
      .gi--open { opacity: 0.5; }
      .gi--in_progress { color: var(--life-in_progress); }
      .gi--blocked { color: var(--life-blocked); font-weight: 700; }
      .gi--done { color: var(--life-done); }
      .gi--cancelled { color: var(--life-cancelled); }
      .gi--considering { color: var(--life-considering); opacity: 0.75; }
      .gi--researching { color: var(--life-researching); opacity: 0.85; }
      .gi--unknown { color: var(--fg-dim); opacity: 0.6; }
      .tl-pager {
        display: flex; align-items: center; justify-content: center; gap: 14px;
        margin: 16px 0 8px; color: var(--muted-text); font-variant-numeric: tabular-nums;
      }
    </style>
    """
  end
end
