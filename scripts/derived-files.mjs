// The committed derived files a PR has to keep fresh, as one map: what each
// step reads, which steps it waits for, how CI catches it stale and how it is
// rebuilt. `scripts/regen.mjs` runs the rebuilds in order; `scripts/reach.mjs`
// maps a diff onto the steps and gates it reaches. task-e04a2c419fdd3621.
//
// A step's `write` is the generator that already exists for it, run from the
// repo root. When it has a `check`, regen runs the check first and writes only
// when the check fails or a step it waits for was rewritten, so a rerun on a
// fresh tree writes nothing (a conformance report's `ran_at_sha` stays put).

const MIX = "cd api && MIX_ENV=test mix";
const RENDER = [
  "api/lib/barkpark/portable_doc/render.ex",
  "api/lib/barkpark/portable_doc/render/**",
  "api/lib/barkpark/portable_doc/slots.ex",
];
// These modules feed rendered blocks even though they live outside render/.
// Changes to them have to rebuild the HTML-producing goldens too.
const RENDERED = [
  ...RENDER,
  "api/lib/barkpark/portable_doc/constraints.ex",
  "api/lib/barkpark/portable_doc/master_ref.ex",
  "api/lib/barkpark/portable_doc/task_resolver.ex",
  "api/lib/barkpark/portable_doc/text_diff.ex",
  "api/lib/barkpark/portable_doc/tiers.ex",
  "api/lib/barkpark/portable_doc/validate.ex",
  "api/lib/barkpark/chat/tool_rows.ex",
  "api/lib/barkpark/plugins/sheets.ex",
  "api/lib/barkpark/plugins/sheets/**",
];
// The golden pack wraps rendered blocks in the Bulldocs reader page for each
// locale Tenancy exposes.
const READER_PAGE = [
  "api/lib/barkpark_web/layouts.ex",
  "api/lib/barkpark_web/layouts/bulldocs*.heex",
  "api/lib/barkpark_web/components/share_meta.ex",
  "api/lib/barkpark/tenancy.ex",
];
// The Studio paper editor rendered by the flag-off snapshot.
const PAPER_EDITOR_VIEW = [
  "api/lib/barkpark_web/live/studio/**",
  "api/lib/barkpark_web/components/field_inputs.ex",
  "api/lib/barkpark_web/components/studio_components/**",
  "api/lib/barkpark_web/studio/save_status.ex",
  "api/lib/barkpark_web/paper_canvas_lease.ex",
  "api/lib/barkpark/portable_doc/projection.ex",
  "api/lib/barkpark/portable_doc/table_editing.ex",
  "api/lib/barkpark/content/papers/template.ex",
];
const GETTEXT = ["api/priv/gettext/**/*.po", "api/lib/barkpark_web/studio_locale.ex"];
const SNAPSHOT = "test/barkpark_web/live/studio/studio_live_paper_canvas_test.exs:182";
const PACK_GATES = [
  "api/test/barkpark/portable_doc/golden_pack_test.exs",
  "api/test/barkpark/portable_doc/render/pd_golden_parity_test.exs",
];

function conformance(name, { inputs, check, write, gate }) {
  return {
    name: `conformance-${name}`,
    inputs: [...inputs, "api/priv/portable_doc/conformance/conformance.mjs"],
    after: ["golden-pack"],
    check,
    write,
    gates: [gate, "api/test/barkpark/portable_doc/conformance_test.exs"],
  };
}

export const STEPS = [
  {
    name: "design-emit",
    inputs: [
      "design/tokens.json",
      "design/themes/**",
      "design/status-manifest.json",
      "design/emit.mjs",
      "design/emit-manifest.json",
      "cloud/priv/audit-actions.json",
    ],
    after: [],
    check: "node design/emit.mjs --check",
    write: "node design/emit.mjs --write",
    gates: [".github/workflows/doc-gates.yml: Design-token drift gate (node design/check.mjs)"],
  },
  {
    name: "paper-editor",
    inputs: [
      "api/assets/paper-editor/src/**",
      "api/assets/paper-editor/scripts/**",
      "api/assets/paper-editor/index.d.ts",
      "api/assets/paper-editor/EMBED-CONTRACT.md",
      "api/assets/paper-editor/package.json",
      "api/assets/paper-editor/package-lock.json",
      "api/assets/paper-surface/**",
      ...RENDER,
    ],
    after: ["design-emit"],
    write:
      "cd api/assets/paper-editor && (test -d node_modules || npm ci) && npm run build:web",
    gates: [
      ".github/workflows/paper-editor.yml: Assert committed bundle and stylesheet are fresh",
      "api/assets/paper-editor/src/__surface.test.mjs",
      "api/test/barkpark/paper_editor_vendor_drift_test.exs",
    ],
  },
  {
    name: "pd-spec",
    inputs: [
      "api/lib/barkpark/portable_doc/spec.ex",
      "api/lib/barkpark/portable_doc/spec/**",
      "api/lib/mix/tasks/barkpark.portable_doc.gen_spec.ex",
    ],
    after: [],
    write: `${MIX} barkpark.portable_doc.gen_spec`,
    gates: ["api/test/barkpark/portable_doc/spec_test.exs"],
  },
  {
    name: "email-golden",
    inputs: [
      ...RENDERED,
      "api/test/support/portable_doc_parity_fixture.ex",
      "api/lib/mix/tasks/barkpark.portable_doc.gen_golden_email.ex",
    ],
    after: ["design-emit"],
    write: `${MIX} barkpark.portable_doc.gen_golden_email`,
    gates: ["api/test/barkpark/portable_doc/render/email_golden_test.exs"],
  },
  {
    name: "component-goldens",
    inputs: [
      "api/lib/barkpark/portable_doc/render/components.ex",
      "api/lib/barkpark/portable_doc/render/status_vocab.ex",
      "api/lib/barkpark/portable_doc/slots.ex",
      "design/status-manifest.json",
      "api/lib/mix/tasks/barkpark.paper_components.gen_golden_parity.ex",
    ],
    after: ["design-emit"],
    write: `${MIX} barkpark.paper_components.gen_golden_parity`,
    gates: ["api/test/barkpark/portable_doc/render/component_golden_parity_test.exs"],
  },
  {
    name: "chat-goldens",
    inputs: [
      "api/lib/barkpark/portable_doc/render/components.ex",
      "api/lib/barkpark/chat/tool_rows.ex",
      "api/lib/barkpark/portable_doc/text_diff.ex",
      "api/lib/barkpark/portable_doc/from_markdown.ex",
      "api/lib/barkpark/studio_chat/**",
      "api/lib/mix/tasks/barkpark.chat.gen_golden_*.ex",
    ],
    after: ["design-emit"],
    write: `${MIX} barkpark.chat.gen_golden_toolrows && MIX_ENV=test mix barkpark.chat.gen_golden_transcript`,
    gates: [
      "api/test/barkpark/chat_golden_toolrows_parity_test.exs",
      "api/test/barkpark/chat_golden_transcript_parity_test.exs",
    ],
  },
  {
    name: "golden-pack",
    inputs: [
      ...RENDERED,
      ...READER_PAGE,
      ...GETTEXT,
      "api/assets/paper-surface/**",
      "api/lib/barkpark/plugins/bulldocs/**",
      "api/lib/barkpark/content/papers/block_ops.ex",
      "api/lib/barkpark/portable_doc/patch.ex",
      "api/lib/mix/tasks/barkpark.portable_doc.gen_pd_parity*.ex",
      "api/lib/mix/tasks/barkpark.portable_doc.gen_golden_email.ex",
      "api/test/support/fixtures/nested-list-carriers.json",
    ],
    after: ["design-emit"],
    write: `${MIX} barkpark.portable_doc.gen_pd_parity`,
    gates: [
      ...PACK_GATES,
      ".github/workflows/js-tests.yml: pd-golden mirror freshness (cd js && pnpm --filter @barkpark/react exec vitest run tests/pd-golden-mirror-parity.test.ts)",
    ],
  },
  conformance("elixir", {
    inputs: [...RENDERED, "api/lib/mix/tasks/barkpark.portable_doc.conformance.ex"],
    check: `${MIX} barkpark.portable_doc.conformance`,
    write: `cd api && CONFORMANCE_WRITE=1 MIX_ENV=test mix barkpark.portable_doc.conformance`,
    gate: "api/lib/mix/tasks/barkpark.portable_doc.conformance.ex",
  }),
  conformance("editor-canvas", {
    inputs: ["api/assets/paper-editor/src/**"],
    check: "cd api/assets/paper-editor && (test -d node_modules || npm ci) && node src/__conformance.mjs",
    write: "cd api/assets/paper-editor && (test -d node_modules || npm ci) && CONFORMANCE_WRITE=1 node src/__conformance.mjs",
    gate: ".github/workflows/paper-editor.yml: PortableDoc conformance (editor canvas vs the golden pack)",
  }),
  conformance("react", {
    inputs: ["js/packages/react/src/**", "js/packages/react/tests/conformance.test.tsx"],
    check:
      "cd js && (test -d node_modules || pnpm install --frozen-lockfile) && pnpm --filter @barkpark/core build && pnpm --filter @barkpark/react exec vitest run tests/conformance.test.tsx",
    write:
      "cd js && (test -d node_modules || pnpm install --frozen-lockfile) && pnpm --filter @barkpark/core build && CONFORMANCE_WRITE=1 pnpm --filter @barkpark/react exec vitest run tests/conformance.test.tsx",
    gate: "js/packages/react/tests/conformance.test.tsx",
  }),
  conformance("pdrender", {
    inputs: ["internal/pdrender/**"],
    check: "go test ./internal/pdrender -run '^TestConformance$' -count=1",
    write: "CONFORMANCE_WRITE=1 go test ./internal/pdrender -run '^TestConformance$' -count=1",
    gate: "internal/pdrender/conformance_test.go",
  }),
  conformance("pdrender-wasm", {
    inputs: ["internal/pdrender/**", "cmd/pdrender-wasm/**"],
    check: "make wasm && node cmd/pdrender-wasm/conformance.mjs",
    write: "make wasm && CONFORMANCE_WRITE=1 node cmd/pdrender-wasm/conformance.mjs",
    gate: "cmd/pdrender-wasm/conformance.mjs",
  }),
  conformance("mobile", {
    inputs: ["apps/mobile/src/**", "apps/mobile/__tests__/conformance.test.tsx", "js/packages/react/src/**"],
    check:
      "(test -d node_modules || pnpm install --frozen-lockfile) && pnpm --filter @barkpark/core build && pnpm --filter @barkpark/react build && cd apps/mobile && pnpm exec jest __tests__/conformance.test.tsx",
    write:
      "(test -d node_modules || pnpm install --frozen-lockfile) && pnpm --filter @barkpark/core build && pnpm --filter @barkpark/react build && cd apps/mobile && CONFORMANCE_WRITE=1 pnpm exec jest __tests__/conformance.test.tsx",
    gate: "apps/mobile/__tests__/conformance.test.tsx",
  }),
  {
    name: "showcase-seeds",
    inputs: ["js/packages/create-barkpark-app/scripts/gen-showcase-content.mjs"],
    after: ["golden-pack"],
    write: "cd js/packages/create-barkpark-app && node scripts/gen-showcase-content.mjs",
    gates: ["js/packages/create-barkpark-app/tests/showcase-content.test.ts"],
  },
  {
    name: "cloud-templates",
    inputs: ["js/packages/create-barkpark-app/templates/**", "scripts/sync-starter-templates.mjs"],
    after: ["showcase-seeds"],
    write: "node scripts/sync-starter-templates.mjs",
    gates: ["cloud/test/barkpark_cloud/templates/app_files_drift_test.exs"],
  },
  {
    name: "studio-snapshot",
    inputs: [...GETTEXT, ...RENDERED, ...PAPER_EDITOR_VIEW],
    after: ["design-emit"],
    check: `${MIX} test ${SNAPSHOT}`,
    write: `cd api && GOLDEN_REGEN=1 MIX_ENV=test mix test ${SNAPSHOT}`,
    gates: ["api/test/barkpark_web/live/studio/studio_live_paper_canvas_test.exs"],
  },
  {
    name: "reader-style-goldens",
    inputs: [...RENDERED, ...GETTEXT, "api/lib/barkpark/plugins/bulldocs/**"],
    after: ["design-emit"],
    check: `${MIX} test test/barkpark_web/live/bulldocs_reader_style_default_test.exs`,
    write: `cd api && REGEN_READER_STYLE_GOLDENS=1 MIX_ENV=test mix test test/barkpark_web/live/bulldocs_reader_style_default_test.exs`,
    gates: ["api/test/barkpark_web/live/bulldocs_reader_style_default_test.exs"],
  },
  {
    name: "chat-render-goldens",
    inputs: [...GETTEXT, "api/lib/barkpark_web/live/studio/**", "api/lib/barkpark/studio_chat/**"],
    after: ["design-emit"],
    check: `${MIX} test test/barkpark_web/live/studio/chat_render_golden_test.exs`,
    write: `cd api && GOLDEN_REGEN=1 MIX_ENV=test mix test test/barkpark_web/live/studio/chat_render_golden_test.exs`,
    gates: ["api/test/barkpark_web/live/studio/chat_render_golden_test.exs"],
  },
];

export function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      const slash = glob[i + 2] === "/";
      re += slash ? "(?:.*/)?" : ".*";
      i += slash ? 2 : 1;
    } else if (c === "*") re += "[^/]*";
    else re += c.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

export function matches(path, globs) {
  return globs.some((g) => globToRegExp(g).test(path));
}

const byName = new Map(STEPS.map((s) => [s.name, s]));

export function step(name) {
  const s = byName.get(name);
  if (!s) throw new Error(`no derived-file step named ${name}`);
  return s;
}

export function ordered(steps = STEPS) {
  const want = new Set(steps.map((s) => s.name));
  const out = [];
  const seen = new Set();
  const visit = (s) => {
    if (seen.has(s.name)) return;
    seen.add(s.name);
    s.after.forEach((d) => visit(step(d)));
    if (want.has(s.name)) out.push(s);
  };
  STEPS.forEach(visit);
  return out;
}

export function reached(paths) {
  const hit = new Set(STEPS.filter((s) => paths.some((p) => matches(p, s.inputs))).map((s) => s.name));
  let grew = true;
  while (grew) {
    grew = false;
    for (const s of STEPS) {
      if (!hit.has(s.name) && s.after.some((d) => hit.has(d))) {
        hit.add(s.name);
        grew = true;
      }
    }
  }
  return ordered(STEPS.filter((s) => hit.has(s.name)));
}
