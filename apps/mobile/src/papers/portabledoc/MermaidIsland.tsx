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
// WHY CDN MERMAID: the reader is online-only in v1 (papers stream live off
// /v1/data/query — there is no offline cache yet, that's wave 3), so the
// island may assume the same network the paper itself needed. Bundling
// mermaid (~2.5 MB) into the APK for a v1 reader would be dead weight on
// every install to save one conditional fetch. On ANY failure — offline,
// CDN unreachable, mermaid parse error, WebView crash — the island degrades
// to the honest styled placeholder (label + verbatim diagram source), never
// a blank hole and never a crash.
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
// directions; (3) onShouldStartLoadWithRequest denies every navigation after
// the initial HTML load, so even fully compromised island content cannot
// take the WebView anywhere. mermaid runs securityLevel:'strict' on top.
//
// HEIGHT: the island cannot know its rendered height up front. It starts at
// a fixed estimate and self-reports the real content height once via
// postMessage. The cap is a malformed-message guard ONLY (non-finite or
// absurd reports) — when it ever engages, the island says "diagram
// truncated" out loud instead of silently clipping (F4; the 1200dp silent
// clip the emulator round caught is the lesson).
import { useMemo, useState } from 'react'
import { StyleSheet, Text, View } from 'react-native'
import { WebView } from 'react-native-webview'

import type { Theme } from '../../ui/theme'

const MERMAID_CDN = 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js'
const INITIAL_HEIGHT = 220
// Malformed-height-report guard, NOT a design limit: a finite report above
// this is treated as suspect, clamped, and labeled "diagram truncated" so
// nothing ever silently vanishes. Honest tall diagrams (the capstone's login
// flowchart is ~2000 dp) sit far below it.
const MAX_HEIGHT = 8000

/** Embed author content in a <script> context: JSON string literal with "<"
 * forced to the \u003c form so "</script>"/"<!--" in the source can never terminate
 * the script element at the HTML-parser level. Exported for the jest suite. */
export function scriptStringLiteral(s: string): string {
  return JSON.stringify(s).replace(/</g, '\\u003c')
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
  const [height, setHeight] = useState(INITIAL_HEIGHT)
  const [truncated, setTruncated] = useState(false)
  const [failed, setFailed] = useState(false)
  const html = useMemo(() => islandHtml(source, theme), [source, theme])

  if (source.trim() === '') return null
  if (failed) return <Placeholder source={source} theme={theme} note="Diagram (mermaid) — could not render" />

  return (
    <View style={[styles.island, { borderColor: theme.border, backgroundColor: theme.surface }]}>
      <WebView
        source={{ html }}
        originWhitelist={['*']}
        // F1 ring 3: the island loads exactly ONE document — its own inline
        // HTML. Every subsequent navigation (tapped link, injected redirect,
        // window.location games) is denied here at the native seam.
        onShouldStartLoadWithRequest={(request) => {
          const url = request.url
          return url === 'about:blank' || url.startsWith('data:') || url.startsWith('about:')
        }}
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
              const wanted = Math.max(msg.px + 16, 60)
              if (wanted > MAX_HEIGHT) {
                // Suspect report — clamp, but say so instead of silently clipping.
                setHeight(MAX_HEIGHT)
                setTruncated(true)
              } else {
                setHeight(wanted)
                setTruncated(false)
              }
            } else if (msg.kind === 'error') {
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
  placeholderLabel: { fontSize: 12, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  placeholderSource: { fontFamily: 'monospace', fontSize: 11, lineHeight: 16 },
  truncatedNote: { fontSize: 11, fontStyle: 'italic', marginTop: 4 },
})
