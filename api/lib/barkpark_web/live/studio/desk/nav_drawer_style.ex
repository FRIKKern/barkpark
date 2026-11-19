defmodule BarkparkWeb.Studio.Desk.NavDrawerStyle do
  @moduledoc """
  The look of the desk navbar's perspective picker (`PerspectivePicker`), its
  drawer (`NavDrawer`) and the bar at phone width, after the TanStack Studio's
  `styles.css` (`.perspective-picker`, `.perspective-menu`, `.nav-drawer`,
  `.drawer-item`, and the J46 `@media` blocks):

  - Under 900 px the tools and the user menu give way, and "Open menu" opens
    the drawer.
  - Under 600 px the bar is one row: the brand's pieces sit in it, the
    workspace name takes what is left and ends in "…", Help and Network
    shares move into the drawer, and search moves to the far right. On the
    narrowest phones the perspective's label gives way too, as TanStack's.
  - On a touch screen (`pointer: coarse`) every target in the bar is 44 px;
    a narrow desktop window keeps 25 px.
  - In the published perspective the bar turns green, as Sanity's.

  Colours are the desk's tokens (`--dk-*`, `Desk.Style`).
  """
  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .studio-shell:has(.dk) .navbar .perspective-picker { box-sizing: border-box; display: inline-flex; align-items: center; height: 33px; padding: 0 5px 0 13px; border: 0; border-radius: 999px; box-shadow: inset 0 0 0 1px var(--dk-line-strong); background: var(--dk-nav-bg); font: inherit; font-size: 13px; font-weight: 500; color: var(--dk-nav-fg); white-space: nowrap; cursor: pointer; }
      .studio-shell:has(.dk) .navbar .perspective-picker:hover { background: var(--dk-nav-hover); }
      .studio-shell:has(.dk) .navbar .perspective-picker:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .navbar .perspective-picker > .dot { margin-right: 20px; }
      .studio-shell:has(.dk) .navbar .perspective-picker > svg { flex: none; width: 21px; height: 21px; margin-left: 12px; color: var(--dk-icon-muted); }
      .studio-shell:has(.dk) .navbar .perspective-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
      .studio-shell:has(.dk) .navbar :is(.perspective-picker, .perspective-menu) .dot { display: inline-block; flex: none; width: 7px; height: 7px; border-radius: 50%; }
      .studio-shell:has(.dk) .navbar .dot.published { background: var(--dk-published); }
      .studio-shell:has(.dk) .navbar .dot.draft-ring { background: none; box-shadow: inset 0 0 0 1.5px var(--dk-caution-dot); }
      .studio-shell:has(.dk) .navbar .perspective-menu { min-width: 204px; font-weight: 400; }
      .studio-shell:has(.dk) .navbar .perspective-menu .dk-menu-item { min-height: 35px; }
      .studio-shell:has(.dk) .navbar .perspective-menu .dot { margin: 0 12px 0 6px; }
      .studio-shell:has(.dk) .navbar .perspective-menu .dk-menu-item[aria-checked="true"] { background: var(--dk-selected); color: var(--dk-on-selected); }
      .studio-shell:has(.dk) .navbar .perspective-menu .dk-menu-item[aria-checked="true"]::after { content: none; }
      .studio-shell:has(.dk) .navbar .perspective-menu .dk-menu-item:focus-visible { box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .navbar:has(.perspective[data-perspective="published"]) { background: color-mix(in srgb, var(--dk-published) 10%, var(--dk-nav-bg)); }
      .studio-shell:has(.dk) .navbar:has(.perspective[data-perspective="published"]) .perspective-picker { box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--dk-published) 45%, var(--dk-nav-bg)); background: color-mix(in srgb, var(--dk-published) 10%, var(--dk-nav-bg)); }
      .studio-shell:has(.dk) .navbar .nav-drawer-wrap { display: none; }
      .studio-shell:has(.dk) .navbar .nav-drawer { box-sizing: border-box; position: fixed; inset: 0 auto 0 0; width: min(280px, calc(100vw - 48px)); height: 100%; max-width: none; max-height: none; margin: 0; padding: 0; border: 0; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-size: 13px; font-weight: 500; }
      .studio-shell:has(.dk) .navbar .nav-drawer[open] { display: flex; flex-direction: column; }
      .studio-shell:has(.dk) .navbar .nav-drawer::backdrop { background: var(--dk-backdrop); }
      .studio-shell:has(.dk) .navbar .nav-drawer header { display: flex; align-items: center; gap: 10px; min-height: 50px; padding: 4px 12px; border-bottom: 1px solid var(--dk-border); }
      .studio-shell:has(.dk) .navbar .nav-drawer header .avatar { width: 33px; height: 33px; font-size: 12px; }
      .studio-shell:has(.dk) .navbar .drawer-who { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--dk-fg); }
      .studio-shell:has(.dk) .navbar .nav-drawer nav { display: flex; flex-direction: column; gap: 4px; padding: 8px; }
      .studio-shell:has(.dk) .navbar .drawer-item { box-sizing: border-box; display: flex; align-items: center; justify-content: space-between; width: 100%; min-height: 33px; padding: 0 12px; border: 0; border-radius: 3px; background: none; font: inherit; color: var(--dk-menu-fg); text-align: left; text-decoration: none; cursor: pointer; }
      .studio-shell:has(.dk) .navbar .drawer-item:hover { background: var(--dk-nav-hover); }
      .studio-shell:has(.dk) .navbar .drawer-item:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .navbar .drawer-item.on { background: var(--dk-nav-selected); color: var(--dk-nav-selected-fg); }
      .studio-shell:has(.dk) .navbar .drawer-item[aria-disabled="true"] { opacity: 0.45; cursor: not-allowed; }
      .studio-shell:has(.dk) .navbar .drawer-item.check { justify-content: flex-start; gap: 8px; }
      .studio-shell:has(.dk) .navbar .drawer-item.check[aria-pressed="true"] { background: var(--dk-nav-selected); color: var(--dk-nav-selected-fg); }
      .studio-shell:has(.dk) .navbar .drawer-item.check[aria-pressed="true"]::after { content: "✓"; margin-left: auto; color: var(--dk-muted); }
      .studio-shell:has(.dk) .navbar .drawer-item .menu-icon-text { display: inline-flex; align-items: center; gap: 8px; }
      .studio-shell:has(.dk) .navbar .drawer-item svg { flex: none; width: 21px; height: 21px; }
      .studio-shell:has(.dk) .navbar .drawer-foot { margin-top: auto; display: flex; flex-direction: column; gap: 4px; padding: 8px; border-top: 1px solid var(--dk-border); }
      .studio-shell:has(.dk) .navbar .drawer-foot hr { width: 100%; margin: 4px 0; border: 0; border-top: 1px solid var(--dk-border); }
      .studio-shell:has(.dk) .navbar .drawer-signout { display: contents; }
      @media (pointer: coarse) {
        .studio-shell:has(.dk) .navbar .drawer-item { min-height: 44px; }
        .studio-shell:has(.dk) .navbar .perspective-menu .dk-menu-item { min-height: 44px; }
      }
      @media (max-width: 899px) {
        .studio-shell:has(.dk) .navbar .nav-drawer-wrap { display: flex; }
        .studio-shell:has(.dk) .navbar .dk-nav, .studio-shell:has(.dk) .navbar #dk-user { display: none; }
      }
      @media (max-width: 768px) and (pointer: coarse) {
        .studio-shell:has(.dk) .navbar .perspective-picker { min-height: 44px; }
        .studio-shell:has(.dk) .navbar .studio-bar-right { gap: 0; }
      }
      @media (max-width: 599px) {
        .studio-shell:has(.dk) .studio-bar.navbar { display: flex; flex-wrap: nowrap; align-items: center; gap: 0; height: 52px; padding: 0 4px; }
        .studio-shell:has(.dk) .navbar .studio-bar-brand { display: contents; }
        .studio-shell:has(.dk) .navbar .logo { margin: 0 8px 0 4px; }
        .studio-shell:has(.dk) .navbar .logo + .scope-switcher { margin-left: 0; }
        .studio-shell:has(.dk) .navbar .scope-switcher { flex: 1 1 0; min-width: 64px; }
        .studio-shell:has(.dk) .navbar .scope-button { max-width: 100%; }
        .studio-shell:has(.dk) .navbar .studio-bar-right { order: 2; flex: 0 1 auto; margin-left: auto; min-width: 0; flex-wrap: nowrap; }
        .studio-shell:has(.dk) .navbar .nav-shares { display: none; }
        .studio-shell:has(.dk) .navbar .nav-search { order: 3; flex: none; }
        .studio-shell:has(.dk) .navbar #dk-help > #help-menu { display: none; }
        .studio-shell:has(.dk) .navbar #dk-help-menu { inset: 52px 4px auto auto !important; margin: 0 !important; }
        .studio-shell:has(.dk) .navbar .menu-wrap.perspective { flex: 0 1 auto; min-width: 0; }
        .studio-shell:has(.dk) .navbar .perspective-picker { max-width: 100%; min-width: 44px; }
        .studio-shell:has(.dk) .navbar .studio-bar-right > :not(.perspective) { flex: none; }
      }
      @media (max-width: 599px) and (pointer: fine) {
        .studio-shell:has(.dk) .studio-bar.navbar { padding: 0 12px; }
        .studio-shell:has(.dk) .navbar .studio-bar-right { padding-left: 8px; }
        .studio-shell:has(.dk) .navbar .nav-search { margin-left: 4px; }
      }
    </style>
    """
  end
end
