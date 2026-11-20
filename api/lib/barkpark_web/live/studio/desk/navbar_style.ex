defmodule BarkparkWeb.Studio.Desk.NavbarStyle do
  @moduledoc """
  The look of the desk navbar's brand, switcher, help, who-is-here and user
  menus (`ScopeSwitch`, `HelpMenu`, `WhoMenu`, `UserMenu`), after the
  TanStack Studio's `styles.css` (`.navbar .logo`, `.brand-button`,
  `.scope-popover`, `.scope-place`, `.user-head`, `.studio-version`,
  `.update-dot`, `.who-dot`, `.who-menu`): 25 px icon
  buttons with 21 px icons, 44 px on a touch screen (`pointer: coarse`), as
  every button in the bar. The menus are `Desk.Menu`'s (`.dk .dk-menu`):
  each wrapper carries `dk`, so they take its tokens and its look.

  Who is here's menu hangs from its button's right edge, and it stays 4 px
  inside the window, as TanStack's (`centre()`): where it would run past the
  left edge it moves to 4 px from the right one (`@position-try`), and it is
  never wider than the window less 8 px (a long name ellipsizes).

  Under 600 px the bar has no room for your own avatar beside the others'
  button, and TanStack's phone bar draws none (its user menu is in the
  drawer): the presence pill gives way there.

  Colours are the desk's tokens (`--dk-*`, `Desk.Style`) and the design
  tokens. A place's icon is the hue `ScopeSwitch` gives it.
  """
  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .studio-shell:has(.dk) .navbar .studio-bar-brand { gap: 8px; }
      .studio-shell:has(.dk) .navbar .logo { flex: none; box-sizing: border-box; width: 25px; height: 25px; border-radius: 4px; display: grid; place-items: center; background: var(--primary); color: var(--primary-fg); font-size: 11px; font-weight: 600; line-height: 1; }
      .studio-shell:has(.dk) .navbar .logo + .scope-switcher { margin-left: -4px; }
      .studio-shell:has(.dk) .navbar .dk-scope { position: relative; min-width: 0; display: flex; }
      .studio-shell:has(.dk) .navbar .scope-button { display: inline-flex; align-items: center; gap: 4px; min-width: 0; max-width: 320px; padding: 3px 6px 3px 8px; border: 0; border-radius: 3px; background: none; font: inherit; font-weight: 500; color: var(--dk-nav-fg); cursor: pointer; }
      .studio-shell:has(.dk) .navbar .scope-button:hover, .studio-shell:has(.dk) .navbar .scope-switcher:has(.scope-popover:popover-open) .scope-button { background: var(--dk-nav-hover); color: var(--dk-nav-hover-fg); }
      .studio-shell:has(.dk) .navbar .scope-button:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .navbar .scope-button svg { flex: none; width: 17px; height: 17px; color: var(--fg-muted); }
      .studio-shell:has(.dk) .navbar .brand-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .scope-popover { box-sizing: border-box; width: 280px; padding: 0; border: 0; border-radius: 6px; background: var(--dk-nav-bg); color: var(--dk-nav-fg); box-shadow: var(--dk-popover-shadow); font-weight: 400; }
      .studio-shell:has(.dk) .navbar .scope-popover:popover-open { display: flex; flex-direction: column; }
      .studio-shell:has(.dk) .navbar .scope-head { display: flex; flex-direction: column; padding: 20px 20px 16px; }
      .studio-shell:has(.dk) .navbar .scope-card { display: flex; align-items: center; gap: 8px; }
      .studio-shell:has(.dk) .navbar .scope-card-logo { width: 41px; height: 41px; font-size: 15px; }
      .studio-shell:has(.dk) .navbar .scope-card-text { display: flex; flex-direction: column; min-width: 0; padding-top: 4px; }
      .studio-shell:has(.dk) .navbar .scope-card-where { margin-bottom: -2px; font-size: 10px; line-height: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .scope-card-name { font-size: 15px; line-height: 23px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .scope-places { border-top: 1px solid var(--dk-nav-border); padding: 8px 0 4px; max-height: 40vh; overflow-y: auto; }
      .studio-shell:has(.dk) .navbar .scope-places section + section { margin-top: 8px; }
      .studio-shell:has(.dk) .navbar .scope-places-head { margin: 0; padding: 8px 20px; font-size: 10px; line-height: 15px; font-weight: 500; }
      .studio-shell:has(.dk) .navbar .scope-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
      .studio-shell:has(.dk) .navbar .scope-place { display: flex; align-items: center; gap: 8px; box-sizing: border-box; width: calc(100% - 36px); margin: 0 20px 0 16px; padding: 4px; border: 0; border-radius: 3px; background: none; font: inherit; color: inherit; text-align: left; cursor: pointer; }
      .studio-shell:has(.dk) .navbar .scope-place:hover:not(:disabled) { background: var(--dk-nav-hover); }
      .studio-shell:has(.dk) .navbar .scope-place:disabled { cursor: default; opacity: 0.5; }
      .studio-shell:has(.dk) .navbar .scope-place[aria-current] { background: var(--primary); color: var(--primary-fg); opacity: 1; }
      .studio-shell:has(.dk) .navbar .scope-place svg { flex: none; width: 21px; height: 21px; }
      .studio-shell:has(.dk) .navbar .scope-place-icon { flex: none; display: grid; place-items: center; width: 25px; height: 25px; border-radius: 3px; background: hsl(var(--place-hue) 70% 55%); color: var(--primary-fg); font-size: 13px; font-weight: 500; }
      .studio-shell:has(.dk) .navbar .scope-place-text { display: flex; flex-direction: column; min-width: 0; flex: 1; }
      .studio-shell:has(.dk) .navbar .scope-place-title { font-size: 13px; line-height: 16px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .scope-place-sub { font-size: 10px; line-height: 12px; font-weight: 500; opacity: 0.75; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .scope-note { margin: 8px 20px; font-size: 12px; color: var(--fg-muted); }
      .studio-shell:has(.dk) .navbar .dk.menu-wrap, .studio-shell:has(.dk) .navbar .dk.editor { background: none; display: flex; align-items: center; }
      .studio-shell:has(.dk) .navbar .icon-btn { position: relative; box-sizing: border-box; width: 25px; height: 25px; margin: 0; padding: 0; display: grid; place-items: center; border: 0; border-radius: 3px; background: none; color: var(--dk-nav-fg); cursor: pointer; }
      .studio-shell:has(.dk) .navbar .icon-btn:hover { background: var(--dk-nav-hover); color: var(--dk-nav-hover-fg); }
      .studio-shell:has(.dk) .navbar .icon-btn:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .navbar .icon-btn svg { width: 21px; height: 21px; }
      .studio-shell:has(.dk) .navbar .avatar { display: grid; place-items: center; width: 25px; height: 25px; border-radius: 50%; background: var(--dk-selected); color: var(--dk-on-selected); font-size: 10px; font-weight: 600; }
      .studio-shell:has(.dk) .navbar .update-dot { position: absolute; top: 2px; right: 2px; width: 6px; height: 6px; border-radius: 50%; background: var(--dk-caution-dot); box-shadow: 0 0 0 1.5px var(--dk-nav-bg); }
      .studio-shell:has(.dk) .navbar .update-dot[hidden] { display: none; }
      .studio-shell:has(.dk) .navbar .user-menu, .studio-shell:has(.dk) .navbar .help-menu { min-width: 220px; font-weight: 400; }
      .studio-shell:has(.dk) .navbar .user-head { display: flex; align-items: center; gap: 10px; padding: 8px 12px 10px 8px; }
      .studio-shell:has(.dk) .navbar .user-head .avatar { width: 33px; height: 33px; font-size: 12px; }
      .studio-shell:has(.dk) .navbar .user-who { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
      .studio-shell:has(.dk) .navbar .user-name { font-weight: 500; color: var(--dk-fg); }
      .studio-shell:has(.dk) .navbar :is(.user-email, .user-role) { color: var(--dk-muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .studio-shell:has(.dk) .navbar .dk-user-signout { display: contents; }
      .studio-shell:has(.dk) .navbar .dk-menu-item.spread { justify-content: space-between; }
      .studio-shell:has(.dk) .navbar .dk-signout-icon { display: flex; color: var(--dk-icon-muted); }
      .studio-shell:has(.dk) .navbar .dk-signout-icon svg { width: 21px; height: 21px; }
      .studio-shell:has(.dk) .navbar .dk-menu-item.studio-version { align-items: flex-start; justify-content: space-between; gap: 12px; }
      .studio-shell:has(.dk) .navbar .version-text { display: flex; flex-direction: column; text-align: left; }
      .studio-shell:has(.dk) .navbar .version-text .muted { margin-top: -2px; color: var(--dk-icon-muted); }
      .studio-shell:has(.dk) .navbar .version-badge { padding: 1px 5px; border-radius: 3px; background: var(--dk-icon-hover); color: var(--dk-muted); font-size: 12px; text-decoration: none; }
      .studio-shell:has(.dk) .navbar .studio-version[data-update] .version-text .muted { color: var(--warning); }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog { box-sizing: border-box; padding: 0; border: 0; border-radius: 6px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-weight: 400; }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog::backdrop { background: var(--dk-backdrop); }
      .studio-shell:has(.dk) .navbar .version-dialog { width: min(320px, calc(100vw - 32px)); }
      .studio-shell:has(.dk) .navbar .whats-new-dialog { width: min(560px, calc(100vw - 32px)); }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog header { display: flex; align-items: center; justify-content: space-between; padding: 12px 12px 12px 20px; }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog h2 { margin: 0; font-size: 15px; font-weight: 600; }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog .dialog-body { padding: 8px 20px; }
      .studio-shell:has(.dk) .navbar .version-body { display: flex; flex-direction: column; align-items: center; gap: 16px; padding: 32px 20px 12px; text-align: center; }
      .studio-shell:has(.dk) .navbar .version-body p { margin: 0; }
      .studio-shell:has(.dk) .navbar .version-logo { width: 56px; height: 56px; border-radius: 8px; font-size: 22px; }
      .studio-shell:has(.dk) .navbar .version-name { display: flex; align-items: center; gap: 8px; }
      .studio-shell:has(.dk) .navbar .version-state { color: var(--dk-muted); }
      .studio-shell:has(.dk) .navbar .dk-nav-dialog footer { display: flex; padding: 12px 20px 16px; }
      .studio-shell:has(.dk) .navbar .version-dialog footer .publish { flex: 1; justify-content: center; }
      .studio-shell:has(.dk) .navbar .whats-new-foot a { color: var(--dk-fg); text-decoration: none; }
      .studio-shell:has(.dk) .navbar .icon-btn.who .who-dot { position: absolute; top: 6px; right: 6px; width: 4px; height: 4px; border-radius: 3px; background: var(--dk-published); box-shadow: 0 0 0 1px var(--dk-nav-bg); }
      .studio-shell:has(.dk) .navbar .who-menu { box-sizing: border-box; min-width: 260px; max-width: calc(100vw - 8px); position-try-fallbacks: --dk-who-inside; font-weight: 400; }
      @position-try --dk-who-inside { right: 4px; left: auto; }
      .studio-shell:has(.dk) .navbar .who-empty { box-sizing: border-box; display: grid; gap: 2px; width: 260px; margin: -4px; padding: 11px 16px; line-height: 19px; white-space: normal; }
      .studio-shell:has(.dk) .navbar .who-empty p { margin: 0; color: var(--dk-muted); }
      .studio-shell:has(.dk) .navbar .who-empty p:first-child { color: var(--dk-fg); font-weight: 500; }
      .studio-shell:has(.dk) .navbar .who-row { gap: 8px; }
      .studio-shell:has(.dk) .navbar .who-row .avatar { flex: none; color: var(--dk-avatar-fg); }
      .studio-shell:has(.dk) .navbar .who-row:disabled { cursor: default; }
      .studio-shell:has(.dk) .navbar .who-row:disabled .who-name { color: var(--dk-muted); }
      .studio-shell:has(.dk) .navbar .who-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
      .studio-shell:has(.dk) .navbar .who-doc { flex: none; margin-left: auto; max-width: 140px; overflow: hidden; text-overflow: ellipsis; color: var(--dk-muted); font-size: 12px; font-weight: 400; }
      .studio-shell:has(.dk) .navbar :is(.who-menu .who-row:hover, .who-menu:not(:hover) .who-row:focus-visible):not(:disabled) .who-doc { color: inherit; }
      @media (max-width: 599px) {
        .studio-shell:has(.dk) .navbar .presence-me-group { display: none; }
      }
      @media (pointer: coarse) {
        .studio-shell:has(.dk) .navbar button { min-width: 44px; min-height: 44px; }
        .studio-shell:has(.dk) .navbar .icon-btn { width: 44px; height: 44px; }
        .studio-shell:has(.dk) .navbar .scope-place { min-height: 44px; }
      }
    </style>
    """
  end
end
