const common = {
  globals: ["BP_PAPER_EDITOR_NO_INJECT"],
  stubs: ["synthetic document store", "reference fold", "fleet painter"],
};

export const profiles = [
  { id: "studio-canvas", title: "Barkpark Studio canvas", className: "studio", accent: "#16856b", source: "barkpark:api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex", ...common },
  { id: "studio-field-canvas", title: "Barkpark Studio field canvas", className: "studio field", accent: "#3665d6", source: "barkpark:api/lib/barkpark_web/components/field_inputs.ex", ...common },
  { id: "reader-edit", title: "Barkpark reader edit", className: "reader", accent: "#8b5b25", source: "barkpark:api/lib/barkpark_web/live/bulldocs_live/edit.ex", ...common },
  { id: "web-read", title: "Barkpark web/read", className: "web", accent: "#4d6373", source: "barkpark:web/components/document-detail.tsx", ...common },
  { id: "barkdown", title: "Barkdown", className: "barkdown", accent: "#9a4f73", source: "barkdown@e96e211238b1e43e1126ec9864f1e7ad5ff5cf8b:app/renderer/styles.css", ...common },
  { id: "barkever", title: "Barkever", className: "barkever", accent: "#6253a4", source: "barkever@9bb401a05ca79cfd5812d45fb79fe6761cdbbaf4:app/src/styles/editor.css", ...common },
  { id: "barkpark-studio", title: "barkpark-studio", className: "standalone-studio", accent: "#17717d", source: "barkpark-studio@d254857cb099e0261ad88e1f5e8c80dd0576be05:app/src/styles.css", ...common },
];

export const profile = (id) => profiles.find((entry) => entry.id === id);

export function hostCss(entry) {
  return `
:root { --host-accent: ${entry.accent}; }
body { border-top: 4px solid var(--host-accent); }
body::before { content: ${JSON.stringify(entry.title + " · synthetic host")}; display: block; padding: 10px 16px; color: var(--host-accent); font: 600 13px/1.2 system-ui; }
.tg-stamp { top: 40px; }
body.host-field .tg-stage { max-width: 760px; }
body.host-reader .tg-stage { max-width: 980px; }
body.host-web { background-image: linear-gradient(90deg, color-mix(in srgb, var(--host-accent) 5%, transparent), transparent); }
body.host-barkdown .tg-stage { font-family: ui-monospace, SFMono-Regular, monospace; }
body.host-barkever .tg-stage { box-shadow: 0 12px 36px color-mix(in srgb, var(--host-accent) 14%, transparent); }
body.host-standalone-studio .tg-stage { max-width: 1120px; }
`;
}
