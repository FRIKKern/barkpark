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
// HEIGHT: the island cannot know its rendered height up front. It starts at
// a fixed estimate and self-reports the real content height once via
// postMessage; FlatList tolerates the one-time resize (blocks are keyed, and
// the resize lands within a frame of the diagram paint).
import { useMemo, useState } from 'react'
import { StyleSheet, Text, View } from 'react-native'
import { WebView } from 'react-native-webview'

import type { Theme } from '../../ui/theme'

const MERMAID_CDN = 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js'
const INITIAL_HEIGHT = 220
// The cap only guards against a runaway height REPORT (malformed postMessage),
// not against honest tall diagrams: the capstone's login flowchart alone is
// ~2000 dp, and clipping it would silently swallow its tail nodes — the exact
// "never silently vanish" law this renderer lives by. Emulator-proven at 4000.
const MAX_HEIGHT = 4000

function islandHtml(source: string, theme: Theme): string {
  // The diagram source is embedded as a JSON string literal (never innerHTML)
  // so author content cannot break out of the script context.
  const src = JSON.stringify(source)
  const dark = JSON.stringify(theme.bg !== '#f6f7f6')
  return `<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
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
  const [failed, setFailed] = useState(false)
  const html = useMemo(() => islandHtml(source, theme), [source, theme])

  if (source.trim() === '') return null
  if (failed) return <Placeholder source={source} theme={theme} note="Diagram (mermaid) — could not render" />

  return (
    <View style={[styles.island, { borderColor: theme.border, backgroundColor: theme.surface }]}>
      <WebView
        source={{ html }}
        originWhitelist={['*']}
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
            if (msg.kind === 'height' && typeof msg.px === 'number' && msg.px > 0) {
              setHeight(Math.min(Math.max(msg.px + 16, 60), MAX_HEIGHT))
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
    </View>
  )
}

const styles = StyleSheet.create({
  island: { borderWidth: 1, borderRadius: 8, overflow: 'hidden', padding: 8 },
  placeholder: { borderWidth: 1, borderRadius: 8, padding: 12, gap: 6 },
  placeholderLabel: { fontSize: 12, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  placeholderSource: { fontFamily: 'monospace', fontSize: 11, lineHeight: 16 },
})
