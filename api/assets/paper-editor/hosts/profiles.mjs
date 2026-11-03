const commonGlobals = ["BP_PAPER_EDITOR_NO_INJECT"];
const commonStubs = ["synthetic document store", "reference fold", "fleet painter"];

function host(entry) {
  return {
    ...entry,
    globals: [...commonGlobals, ...entry.globals],
    stubs: [...commonStubs, ...entry.stubs],
  };
}

export const profiles = [
  host({ id: "studio-canvas", title: "Barkpark Studio canvas", className: "studio", accent: "#16856b", pickers: true, source: "barkpark:api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex", globals: ["liveViewHook"], stubs: ["Studio save bridge"], css: ".tg-stage { max-width: 1040px; } bp-paper-canvas { --paper-font-ui: system-ui; }" }),
  host({ id: "studio-field-canvas", title: "Barkpark Studio field canvas", className: "studio field", accent: "#3665d6", pickers: true, source: "barkpark:api/lib/barkpark_web/components/field_inputs.ex", globals: ["fieldInputName"], stubs: ["field change event"], css: ".tg-stage { max-width: 760px; } bp-paper-canvas { --paper-rule: #dfe3ec; }" }),
  host({ id: "reader-edit", title: "Barkpark reader edit", className: "reader", accent: "#8b5b25", source: "barkpark:api/lib/barkpark_web/live/bulldocs_live/edit.ex", globals: ["readerRenderer"], stubs: ["reader render response"], css: ".tg-stage { max-width: 980px; } bp-paper-canvas { --paper-reading-accent: #8b5b25; }" }),
  host({ id: "web-read", title: "Barkpark web/read", className: "web", accent: "#4d6373", source: "barkpark:web/components/document-detail.tsx", globals: ["webDocumentSlug"], stubs: ["web route loader"], css: "body { background-image: linear-gradient(90deg, color-mix(in srgb, var(--host-accent) 5%, transparent), transparent); }" }),
  host({ id: "barkdown", title: "Barkdown", className: "barkdown", accent: "#9a4f73", source: "barkdown@e96e211238b1e43e1126ec9864f1e7ad5ff5cf8b:app/renderer/styles.css", globals: ["electronBridge"], stubs: ["native document IPC"], css: ".tg-stage { margin: 6px auto 10px; } bp-paper-canvas { display: block; --paper-font-serif: 'Segoe UI', system-ui; } .ProseMirror { font-size: 14px; line-height: 1.75; min-height: 160px; }" }),
  host({ id: "barkever", title: "Barkever", className: "barkever", accent: "#6253a4", source: "barkever@9bb401a05ca79cfd5812d45fb79fe6761cdbbaf4:app/src/styles/editor.css", globals: ["barkeverStore"], stubs: ["notebook and tag lookup"], css: ".tg-stage { box-shadow: 0 12px 36px color-mix(in srgb, var(--host-accent) 14%, transparent); } bp-paper-canvas { --paper-bg: Canvas; --paper-ink: CanvasText; --paper-accent: #6253a4; --paper-font-sans: system-ui; }" }),
  host({ id: "barkpark-studio", title: "barkpark-studio", className: "standalone-studio", accent: "#17717d", pickers: true, source: "barkpark-studio@d254857cb099e0261ad88e1f5e8c80dd0576be05:app/src/styles.css", globals: ["studioDocumentClient"], stubs: ["Sanity document patch"], css: ".tg-stage { max-width: 1120px; padding: 16px 20px 64px; } bp-paper-canvas { display: block; padding-left: 52px; } @media (max-width: 640px) { .tg-stage { padding: 10px 0 56px; } bp-paper-canvas { padding-left: 0; } }" }),
];

export const profile = (id) => profiles.find((entry) => entry.id === id);

export function hostCss(entry) {
  return `
:root { --host-accent: ${entry.accent}; }
body { border-top: 4px solid var(--host-accent); }
body::before { content: ${JSON.stringify(entry.title + " · synthetic host")}; display: block; padding: 10px 16px; color: var(--host-accent); font: 600 13px/1.2 system-ui; }
.tg-stamp { top: 40px !important; }
${entry.css}
`;
}
