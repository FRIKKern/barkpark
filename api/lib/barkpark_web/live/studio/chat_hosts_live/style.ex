defmodule BarkparkWeb.Studio.ChatHostsLive.Style do
  @moduledoc """
  The look of the Chat hosts page. Every colour is a Studio design token
  (`--fg`, `--ok`, `--warning`, …), so the page follows the theme in light and
  dark and `scripts/studio-literal-check.sh` finds no literal. Scoped under
  `.ch-page`, so nothing here reaches another screen.
  """
  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .ch-page { max-width: 880px; margin: 0 auto; padding: 40px 24px 64px; color: var(--fg); }
      .ch-page code { font-family: var(--font-mono); font-size: 0.92em; }
      .ch-eyebrow { margin: 0 0 6px; font-size: var(--text-xs); font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--fg-muted); }
      .ch-head h1 { margin: 0; font-size: var(--text-2xl); font-weight: 650; letter-spacing: -0.01em; }
      .ch-lede { margin: 10px 0 0; max-width: 62ch; font-size: var(--text-base); line-height: 1.55; color: var(--fg-muted); }
      .ch-steps { list-style: none; margin: 28px 0 0; padding: 0; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
      .ch-steps li { display: flex; gap: 12px; padding: 14px 16px; border: 1px solid var(--border-muted); border-radius: var(--radius-lg); background: var(--bg-card); font-size: var(--text-sm); line-height: 1.5; color: var(--fg-muted); }
      .ch-steps strong { display: block; margin-bottom: 2px; color: var(--fg); font-weight: 600; }
      .ch-step-n { flex: none; display: grid; place-items: center; width: 24px; height: 24px; border-radius: 50%; background: var(--primary-soft); color: var(--primary-text); font-size: var(--text-xs); font-weight: 700; }
      .ch-card { margin-top: 28px; padding: 22px 24px; border: 1px solid var(--border); border-radius: var(--radius-lg); background: var(--bg-card); }
      .ch-card h2, .ch-list h2 { margin: 0; font-size: var(--text-lg); font-weight: 600; }
      .ch-card-sub { margin: 4px 0 18px; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-form { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.6fr) auto; gap: 12px; align-items: end; }
      .ch-field { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
      .ch-field label { font-size: var(--text-sm); font-weight: 500; }
      .ch-field .form-input { width: 100%; }
      .ch-hint { margin: 0; font-size: var(--text-xs); color: var(--muted-text); }
      .ch-note { margin: 28px 0 0; padding: 12px 16px; border-radius: var(--radius); background: var(--bg-muted); font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-list { margin-top: 36px; }
      .ch-list-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
      .ch-count { font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-empty { padding: 28px; border: 1px dashed var(--border); border-radius: var(--radius-lg); text-align: center; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-hosts { display: flex; flex-direction: column; gap: 12px; }
      .ch-host { --ch-tone: var(--fg-dim); padding: 16px 18px; border: 1px solid var(--border-muted); border-left: 3px solid var(--ch-tone); border-radius: var(--radius-lg); background: var(--bg-card); }
      .ch-host--online { --ch-tone: var(--ok); }
      .ch-host--waiting { --ch-tone: var(--info); }
      .ch-host--expired { --ch-tone: var(--warning); }
      .ch-host--offline { --ch-tone: var(--fg-dim); }
      .ch-host-head { display: flex; align-items: center; gap: 10px; }
      .ch-dot { flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--ch-tone); }
      .ch-host--online .ch-dot { box-shadow: 0 0 0 3px var(--ok-soft); }
      .ch-host-name { margin: 0; font-size: var(--text-base); font-weight: 600; }
      .ch-pill { margin-left: auto; padding: 2px 10px; border-radius: 999px; background: var(--bg-muted); font-size: var(--text-xs); font-weight: 600; color: var(--fg-muted); white-space: nowrap; }
      .ch-host--online .ch-pill { background: var(--ok-soft); color: var(--ok-text); }
      .ch-host--waiting .ch-pill { background: var(--info-soft); color: var(--info-text); }
      .ch-host--expired .ch-pill { background: var(--warn-soft); color: var(--warn-text); }
      .ch-host-meta { margin: 6px 0 0 18px; display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-path { font-family: var(--font-mono); font-size: var(--text-xs); padding: 1px 6px; border-radius: var(--radius-sm); background: var(--bg-muted); color: var(--fg); }
      .ch-caps { list-style: none; margin: 10px 0 0 18px; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-caps strong { color: var(--fg); font-weight: 600; margin-right: 4px; }
      .ch-host-note { margin: 10px 0 0 18px; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-code { margin: 14px 0 0 18px; padding: 14px 16px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-muted); }
      .ch-code-lead, .ch-code-next { margin: 0; font-size: var(--text-sm); color: var(--fg-muted); line-height: 1.5; }
      .ch-code-next { margin-top: 10px; }
      .ch-command { display: flex; align-items: flex-start; gap: 10px; margin-top: 10px; }
      .ch-command textarea { flex: 1; min-width: 0; resize: none; padding: 10px 12px; border-radius: var(--radius-sm); background: var(--bg); border: 1px solid var(--border-muted); color: var(--fg); font-family: var(--font-mono); font-size: var(--text-xs); line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; }
      .ch-host-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px; }
      .ch-revoked { margin-top: 28px; font-size: var(--text-sm); color: var(--fg-muted); }
      .ch-revoked h3 { margin: 0 0 6px; font-size: var(--text-sm); font-weight: 600; color: var(--fg-muted); }
      .ch-revoked ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 16px; }
      .ch-foot { margin-top: 36px; padding-top: 16px; border-top: 1px solid var(--border-muted); font-size: var(--text-sm); color: var(--fg-muted); line-height: 1.55; }
      @media (max-width: 720px) {
        .ch-page { padding: 24px 16px 48px; }
        .ch-steps, .ch-form { grid-template-columns: minmax(0, 1fr); }
        .ch-command { flex-direction: column; }
      }
    </style>
    """
  end
end
