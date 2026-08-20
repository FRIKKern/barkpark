// MermaidIsland RING-3 proofs (mob-bl-mermaid-ring3).
//
// Rings 1 (the < script-context escape) and 2 (the CSP meta) are proven in
// paperRenderer.test.tsx under "mermaid island script injection (F1)". This
// suite owns ring 3 — the navigation predicate — plus the securityLevel
// assertion the island's HTML never had, both driven as pure functions so no
// WebView, no emulator and no network are involved.
import { allowNavigation, islandHtml } from '../src/papers/portabledoc/MermaidIsland'
import type { Theme } from '../src/ui/theme'

// react-native-webview is a native TurboModule with no jest mock of its own —
// merely IMPORTING the island module throws RNCWebViewModule-not-found. The
// functions under test never touch it. (jest.mock is hoisted above the imports.)
jest.mock('react-native-webview', () => ({ WebView: () => null }))

const theme = { isDark: false } as unknown as Theme

describe('ring 3 — allowNavigation', () => {
  it('allows the island’s own document', () => {
    // RN WebView presents `source.html` as about:blank on both platforms; this
    // is the ONE navigation the island legitimately performs.
    expect(allowNavigation('about:blank')).toBe(true)
  })

  it.each([
    // A data: document is navigable and carries its OWN origin — the island's
    // CSP meta does not travel with it.
    'data:text/html,<script>fetch("https://evil.example/x")</script>',
    'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==',
    'data:image/svg+xml,<svg onload="alert(1)"/>',
    // about:* is not a family of no-ops: srcdoc is a document boundary.
    'about:srcdoc',
    'about:config',
    'about:',
    // Anything off-device, and the classic script-URL navigation.
    'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js',
    'https://evil.example/phish',
    'http://evil.example/phish',
    'javascript:alert(1)',
    'file:///etc/passwd',
    'barkpark://tasks/t1',
    'intent://evil/#Intent;scheme=https;end',
    '',
  ])('denies %p', (url) => {
    expect(allowNavigation(url)).toBe(false)
  })

  it('matches exactly — no prefix, no case, no whitespace slack', () => {
    for (const near of [
      'about:blank#x',
      'about:blank?x=1',
      'about:blank/',
      'about:blankish',
      'ABOUT:BLANK',
      ' about:blank',
      'about:blank ',
    ]) {
      expect(allowNavigation(near)).toBe(false)
    }
  })
})

describe('the island document pins mermaid to securityLevel strict', () => {
  it('initializes with securityLevel strict', () => {
    const html = islandHtml('flowchart TD\n  A --> B', theme)
    expect(html).toContain("securityLevel:'strict'")
    // Never one of the looser levels — 'loose'/'antiscript' would let author
    // bytes back into the DOM as markup, which is exactly what ring 1 escapes.
    expect(html).not.toContain("securityLevel:'loose'")
    expect(html).not.toContain("securityLevel:'antiscript'")
    expect(html).not.toContain("securityLevel:'sandbox'")
    // startOnLoad:false keeps rendering explicit — mermaid never sweeps the DOM.
    expect(html).toContain('startOnLoad:false')
  })
})
