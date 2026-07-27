// Authored cases for the core-code family (src/papers/portabledoc/blocks/
// core-code.tsx): the five nav/code natives from mob-zb-s4-navcode-natives.
// Every block below is the LIVE authored shape, not a convenient one — the
// filetree/diff pair are trimmed from the committed pd-parity inputs
// (api/lib/mix/tasks/barkpark.portable_doc.gen_pd_parity.ex), so a case that
// stops rendering is a real-content regression, not a fixture quirk.
import type { BlockCase } from './types'

export const coreCodeCases: BlockCase[] = [
  {
    type: 'tabs',
    block: {
      type: 'tabs',
      tabs: [
        { label: 'Install', blocks: [{ type: 'paragraph', text: 'pnpm add @barkpark/react' }] },
        { label: 'Use', blocks: [{ type: 'paragraph', text: 'import { PortableDoc }' }] },
      ],
    },
  },
  {
    type: 'code-tabs',
    block: {
      type: 'code-tabs',
      syncKey: 'lang',
      tabs: [
        { label: 'curl', language: 'bash', value: 'curl /v1/capabilities' },
        { label: 'JS', language: 'javascript', value: 'await bp.capabilities()' },
      ],
    },
  },
  {
    type: 'api-endpoint',
    block: {
      type: 'api-endpoint',
      method: 'post',
      path: '/v1/data/mutate',
      params: [{ name: 'dataset', in: 'path', type: 'string', required: true }],
    },
  },
  {
    type: 'filetree',
    block: {
      type: 'filetree',
      text:
        'api/lib/barkpark/portable_doc/render/\n' +
        '├── components.ex ● diff_html/1 + filetree_html/1\n' +
        '├── compose.ex ○ grew the diff + filetree clauses\n' +
        '└── starter_stub.ex ✕ removed',
      legend: '● created · ○ injected · ✕ removed',
    },
  },
  {
    type: 'diff',
    block: {
      type: 'diff',
      file: 'lib/render/compose.ex',
      lang: 'elixir',
      diff:
        'diff --git a/lib/render/compose.ex b/lib/render/compose.ex\n' +
        'index 3f9c2d1..8a41b7e 100644\n' +
        '--- a/lib/render/compose.ex\n' +
        '+++ b/lib/render/compose.ex\n' +
        '@@ -1,4 +1,5 @@\n' +
        ' defmodule Render.Compose do\n' +
        '-  def compose_block(%{"type" => "starter"}), do: :todo\n' +
        '+  def compose_block(%{"type" => "diff"} = b), do: Components.diff_html(b)\n' +
        '+  def compose_block(%{"type" => "filetree"} = b), do: Components.filetree_html(b)\n' +
        ' end',
    },
  },
]
