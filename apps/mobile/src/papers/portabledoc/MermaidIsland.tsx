// Per-diagram Mermaid WebView ISLAND — the ratified mermaid strategy for the
// native reader (task mob-w2-paper-reader, criterion 3).
//
// WHY AN ISLAND, NOT A FULL-DOC WEBVIEW: the D11 spike verdict killed the
// full-document WebView on its SCROLL axis (43.1 avg fps, 99.3% janky on the
// advisory emulator run) — but its MEMORY axis PASSED with 3.7 MB marginal
// per warm WebView. A per-diagram island is therefore cheap (the corpus
// carries ~43 diagrams across 100 papers, at most a handful mounted at once
// under FlatList virtualization) and jank-free: the island never scrolls
// internally (scrollEnabled={false}), so the FAILing axis simply does not
// apply. The document scroll stays 100% native FlatList.
//
// WHY CDN MERMAID: paper BODIES are cached offline since D42 (state/cache.ts
// read-through), but diagrams are a RECORDED D42 OFFLINE EXCLUSION beside
// images — no mermaid bytes and no rendered SVG are cached, so an offline
// open of a cached paper degrades every diagram honestly instead of drawing
// it (see the exclusion ledger in state/cache.ts's policy comment, and the
// offline island test in paperReaderOffline.test.tsx). Bundling mermaid
// (~2.5 MB) into the APK would be dead weight on every install to save one
// conditional fetch. On ANY failure — offline, CDN unreachable, a hung
// captive-portal fetch (the watchdog below), mermaid parse error, WebView
// crash — the island degrades to the honest styled placeholder (label +
// verbatim diagram source), never a blank hole and never a crash.
//
// FAILED NEVER RESETS UNTIL REMOUNT — decided, not forgotten
// (mob-zb-bl-island-churn-offline criterion 1): regained connectivity does
// not retry a failed island in place. There is no reliable connectivity
// signal inside the island (the WebView is torn down on failure), a retry
// loop against a captive portal burns data on a metered device, and the
// natural reader gesture — scroll away and back — REMOUNTS the island under
// FlatList virtualization, which is the retry. The height memo below makes
// that remount cheap and jump-free.
//
// SECURITY POSTURE (review fix-round F1): the author-supplied diagram source
// is embedded as a JSON string literal with "<" additionally escaped to
// the \u003c form — JSON.stringify alone does NOT escape "<", so a source
// containing
// "</script>" would otherwise close the inline script at the HTML-parser
// level and inject markup before mermaid's securityLevel ever ran. Three
// rings around the island: (1) the \u003c escape keeps author bytes inside
// the JS string context; (2) a CSP meta restricts scripts to the mermaid CDN
// + this document's own inline bootstrap, and blocks all other network
// directions; (3) onShouldStartLoadWithRequest (allowNavigation) allows the
// island's own about:blank document and NOTHING else — not data:, not
// about:srcdoc — so even fully compromised island content cannot take the
// WebView anywhere. mermaid runs securityLevel:'strict' on top.
//
// HEIGHT: the island cannot know its rendered height up front. It starts at
// a fixed estimate and self-reports the real content height once via
// postMessage. The cap is a malformed-message guard ONLY (non-finite or
// absurd reports) — when it ever engages, the island says "diagram
// truncated" out loud instead of silently clipping (F4; the 1200dp silent
// clip the emulator round caught is the lesson).
import { useEffect, useMemo, useState } from 'react'
import { StyleSheet, Text, View } from 'react-native'
import { WebView } from 'react-native-webview'

import type { Theme } from '../../ui/theme'
import { scale } from '../../ui/typography'

const MERMAID_CDN = 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js'
const INITIAL_HEIGHT = 220
// Malformed-height-report guard, NOT a design limit: a finite report above
// this is treated as suspect, clamped, and labeled "diagram truncated" so
// nothing ever silently vanishes. Honest tall diagrams (the capstone's login
// flowchart is ~2000 dp) sit far below it.
const MAX_HEIGHT = 8000
// A captive portal or DNS blackhole neither errors nor resolves — without a
// deadline the island sits as a mute bordered box for the platform timeout.
// ~4s is generous for a CDN script + render on any network worth waiting for.
const WATCHDOG_MS = 4000

// ── last-known-height memo (defect 1: churn) ─────────────────────────────────
// Height is otherwise component-local state: a deep scroll-back REMOUNTS the
// island under FlatList virtualization and it re-painted at INITIAL_HEIGHT
// (probe: 220 → 640 → 656 → remount → 220), a layout jump on every revisit.
// Module-level, keyed by (theme.isDark, source) because the rendered height is
// a pure function of those two; bounded so a long reading session cannot grow
// it without limit (insertion-order eviction — a Map iterates oldest-first).
const HEIGHT_MEMO_CAP = 200
const knownHeights = new Map<string, number>()

export function heightMemoKey(source: string, theme: Theme): string {
  return `${theme.isDark ? 'dark' : 'light'}:${source}`
}

export function rememberHeight(key: string, px: number): void {
  if (!knownHeights.has(key) && knownHeights.size >= HEIGHT_MEMO_CAP) {
    const oldest = knownHeights.keys().next().value
    if (oldest !== undefined) knownHeights.delete(oldest)
  }
  knownHeights.delete(key) // re-insert so recency is what eviction reads
  knownHeights.set(key, px)
}

export function lastKnownHeight(key: string): number | undefined {
  return knownHeights.get(key)
}

/** Jest-only: the memo is module state and must not leak between tests. */
export function resetHeightMemoForTesting(): void {
  knownHeights.clear()
}

/** Embed author content in a <script> context: JSON string literal with "<"
 * forced to the \u003c form so "</script>"/"<!--" in the source can never terminate
 * the script element at the HTML-parser level. Exported for the jest suite. */
export function scriptStringLiteral(s: string): string {
  return JSON.stringify(s).replace(/</g, '\\u003c')
}

/** RING 3, as a pure predicate so it is testable without a WebView.
 *
 * The island loads exactly ONE document: its own inline HTML, which both
 * platforms present as `about:blank` (RN WebView's baseUrl for `source.html`).
 * NOTHING else is a legitimate navigation here, so the allow-list is that one
 * string — no prefix matching.
 *
 * Why the old predicate was too loose: it also allowed any `data:` URL and any
 * `about:` URL. `data:text/html,…` is a full navigable document with its own
 * origin — a compromised island could hand the WebView attacker-authored HTML
 * that the island's CSP meta does not cover (a CSP travels with the document
 * that declares it, not with the WebView) — and `about:srcdoc` is likewise a
 * document boundary, not a no-op. Exported for the jest suite. */
export function allowNavigation(url: string): boolean {
  return url === 'about:blank'
}

/** The island document. Exported for the jest suite (F1: asserts no raw
 * "</script>" from author content survives into the HTML). */
export function islandHtml(source: string, theme: Theme): string {
  const src = scriptStringLiteral(source)
  const dark = theme.isDark ? 'true' : 'false'
  return `<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src https://cdn.jsdelivr.net 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<style>
  html,body{margin:0;padding:0;background:transparent;overflow:hidden}
  #m{display:flex;justify-content:center}
  #m svg{max-width:100%;height:auto}
</style></head><body><div id="m"></div>
<script src="${MERMAID_CDN}"></script>
<script>
(function(){
  var post = function(msg){ window.ReactNativeWebView && window.ReactNativeWebView.postMessage(JSON.stringify(msg)); };
  if (typeof mermaid === 'undefined') { post({kind:'error', why:'cdn'}); return; }
  try {
    mermaid.initialize({ startOnLoad:false, securityLevel:'strict', theme: ${dark} ? 'dark' : 'neutral' });
    mermaid.render('bp-d', ${src}).then(function(out){
      document.getElementById('m').innerHTML = out.svg;
      requestAnimationFrame(function(){
        post({kind:'height', px: document.getElementById('m').scrollHeight});
      });
    }).catch(function(e){ post({kind:'error', why:String(e && e.message || e)}); });
  } catch (e) { post({kind:'error', why:String(e && e.message || e)}); }
})();
</script></body></html>`
}

/** The honest degrade: a labeled box with the verbatim mermaid source. The
 * diagram never silently vanishes. */
function Placeholder({ source, theme, note }: { source: string; theme: Theme; note: string }) {
  return (
    <View style={[styles.placeholder, { backgroundColor: theme.surface, borderColor: theme.border }]}>
      <Text style={[styles.placeholderLabel, { color: theme.textMuted }]}>{note}</Text>
      <Text style={[styles.placeholderSource, { color: theme.textMuted }]} numberOfLines={12}>
        {source}
      </Text>
    </View>
  )
}

export function MermaidIsland({ source, theme }: { source: string; theme: Theme }) {
  const memoKey = heightMemoKey(source, theme)
  // A remount paints at the LAST KNOWN height for this diagram, not the 220
  // estimate — the memo read is the defect-1 fix. The CDN fetch itself is a
  // recorded cost of the remount (the WebView document is torn down with the
  // native view); what the memo removes is the layout jump while it reloads.
  const [height, setHeight] = useState(() => lastKnownHeight(memoKey) ?? INITIAL_HEIGHT)
  const [truncated, setTruncated] = useState(false)
  const [failed, setFailed] = useState(false)
  // Until the island posts its first height (or error), it is WORKING, and it
  // says so (defect 2) — an empty bordered box reads as broken.
  const [settled, setSettled] = useState(false)
  const html = useMemo(() => islandHtml(source, theme), [source, theme])

  // Defect 3, the watchdog: a captive-portal/DNS-blackhole fetch neither
  // errors nor renders. If the island has not settled within WATCHDOG_MS it is
  // declared failed and degrades to the placeholder — the same honest arm
  // every other failure takes. A message landing first disarms it.
  useEffect(() => {
    if (settled || failed) return
    const t = setTimeout(() => setFailed(true), WATCHDOG_MS)
    return () => clearTimeout(t)
  }, [settled, failed])

  if (source.trim() === '') return null
  if (failed) return <Placeholder source={source} theme={theme} note="Diagram (mermaid) — could not render" />

  return (
    <View style={[styles.island, { borderColor: theme.border, backgroundColor: theme.surface }]}>
      {!settled && (
        <Text style={[styles.loadingLabel, { color: theme.textMuted }]}>Loading diagram…</Text>
      )}
      <WebView
        source={{ html }}
        originWhitelist={['*']}
        // F1 ring 3: the island loads exactly ONE document — its own inline
        // HTML. Every subsequent navigation (tapped link, injected redirect,
        // window.location games, a data: document) is denied here at the native
        // seam. See allowNavigation above for the reasoning + its jest proofs.
        onShouldStartLoadWithRequest={(request) => allowNavigation(request.url)}
        // Islands never scroll internally — the D11 scroll FAIL axis is
        // specifically about WebView-internal scrolling; keeping it off keeps
        // the document on the native FlatList scroller.
        scrollEnabled={false}
        overScrollMode="never"
        setSupportMultipleWindows={false}
        androidLayerType="hardware"
        style={{ height, backgroundColor: 'transparent' }}
        onMessage={(ev) => {
          try {
            const msg = JSON.parse(ev.nativeEvent.data) as { kind?: string; px?: number }
            if (msg.kind === 'height' && typeof msg.px === 'number' && Number.isFinite(msg.px) && msg.px > 0) {
              setSettled(true)
              const wanted = Math.max(msg.px + 16, 60)
              if (wanted > MAX_HEIGHT) {
                // Suspect report — clamp, but say so instead of silently clipping.
                setHeight(MAX_HEIGHT)
                setTruncated(true)
                rememberHeight(memoKey, MAX_HEIGHT)
              } else {
                setHeight(wanted)
                setTruncated(false)
                // The PAINTED height (post-padding, post-floor) is what a
                // remount must reproduce, so that is what the memo holds.
                rememberHeight(memoKey, wanted)
              }
            } else if (msg.kind === 'error') {
              setSettled(true)
              setFailed(true)
            }
          } catch {
            // Malformed message — keep the estimate; never crash.
          }
        }}
        onError={() => setFailed(true)}
        onHttpError={() => setFailed(true)}
      />
      {truncated && (
        <Text style={[styles.truncatedNote, { color: theme.textMuted }]}>
          Diagram truncated — reported height exceeded the render guard.
        </Text>
      )}
    </View>
  )
}

const styles = StyleSheet.create({
  island: { borderWidth: 1, borderRadius: 8, overflow: 'hidden', padding: 8 },
  placeholder: { borderWidth: 1, borderRadius: 8, padding: 12, gap: 6 },
  placeholderLabel: { ...scale.xs, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  placeholderSource: { ...scale.micro, fontFamily: 'monospace' },
  truncatedNote: { ...scale.micro, fontStyle: 'italic', marginTop: 4 },
  loadingLabel: { ...scale.micro, fontStyle: 'italic', marginBottom: 4 },
})
