// SPDX-License-Identifier: Apache-2.0
// WebView spike app (charter D11) — THROWAWAY, not product code.
//
// One full-screen react-native-webview 13.16.1 rendering the capstone paper,
// plus N optional "warm" WebViews kept mounted (undestroyed) behind it for the
// memory axis. The WebView OWNS its own scroll — it is deliberately NEVER nested
// in a ScrollView (react-native-webview issue #22; if a future product surface
// must nest, the documented workaround is nestedScrollEnabled on the Android
// side — the spike measures the clean full-screen shape).
//
// Drive it by touch (buttons) or by deep link for one-command adb runs:
//   adb shell am start -W -a android.intent.action.VIEW \
//     -d "bpspike://run?variant=inline&warm=0" cloud.barkpark.webviewspike
//
// Emitted logcat lines (grep for BPSPIKE; they ride the ReactNativeJS tag):
//   [BPSPIKE] prepared variant-files
//   [BPSPIKE] cold-load variant=<v> rn_ms=<N> dom_ms=<M>   <- the verdict number
//   [BPSPIKE] loadend variant=<v> rn_ms=<N>
//   [BPSPIKE] warm-loaded idx=<i>
//   [BPSPIKE] warm-ready count=<N>
//
// rn_ms = performance.now() delta from just-before-WebView-mount to the FMP
// postMessage (double rAF after DOMContentLoaded inside the page) — it includes
// WebView spin-up, which is what a paper-reader tab actually pays. dom_ms is the
// in-page number (navigation start -> FMP) for cross-checking.

import { StatusBar } from 'expo-status-bar'
import { useCallback, useEffect, useRef, useState } from 'react'
import { Linking, Pressable, StyleSheet, Text, View } from 'react-native'
import { WebView } from 'react-native-webview'
import { Directory, File, Paths } from 'expo-file-system'

import { inlineHtml, fileHtml, paperSurfaceCss } from './assets/generated'

const TAG = '[BPSPIKE]'

function parseRunUrl(url) {
  // bpspike://run?variant=inline|file&warm=N
  if (!url || !url.startsWith('bpspike://')) return null
  const q = url.split('?')[1] || ''
  const params = {}
  for (const pair of q.split('&')) {
    const [k, v] = pair.split('=')
    if (k) params[k] = decodeURIComponent(v || '')
  }
  const variant = params.variant === 'file' ? 'file' : 'inline'
  const warm = Math.max(0, Math.min(4, parseInt(params.warm || '0', 10) || 0))
  return { variant, warm }
}

export default function App() {
  const [run, setRun] = useState(null) // { variant: 'inline'|'file', warm: N }
  const [fileUri, setFileUri] = useState(null)
  const [status, setStatus] = useState('preparing variant files…')
  const t0 = useRef(0)
  const warmLoaded = useRef(0)

  // Write the file-variant pair to documentDirectory at boot, BEFORE any run
  // starts — filesystem prep is not part of the cold-load measurement.
  useEffect(() => {
    try {
      const dir = new Directory(Paths.document, 'webview-spike')
      if (!dir.exists) dir.create()
      const html = new File(dir, 'capstone-file.html')
      html.write(fileHtml)
      const css = new File(dir, 'paper-surface.css')
      css.write(paperSurfaceCss)
      setFileUri(html.uri)
      console.log(`${TAG} prepared variant-files`)
      setStatus('ready')
    } catch (e) {
      console.log(`${TAG} ERROR preparing variant files: ${e.message}`)
      setStatus(`file prep failed: ${e.message}`)
    }
  }, [])

  const startRun = useCallback((next) => {
    warmLoaded.current = 0
    t0.current = performance.now()
    setRun(next)
  }, [])

  // Deep-link driving (initial URL for cold starts; url event as a fallback).
  useEffect(() => {
    if (fileUri === null) return
    let cancelled = false
    Linking.getInitialURL().then((url) => {
      const parsed = parseRunUrl(url)
      if (parsed && !cancelled) startRun(parsed)
    })
    const sub = Linking.addEventListener('url', ({ url }) => {
      const parsed = parseRunUrl(url)
      if (parsed) startRun(parsed)
    })
    return () => {
      cancelled = true
      sub.remove()
    }
  }, [fileUri, startRun])

  const onMessage = useCallback(
    (event) => {
      let msg
      try {
        msg = JSON.parse(event.nativeEvent.data)
      } catch {
        return
      }
      if (msg.kind === 'fmp' && run) {
        const rnMs = Math.round(performance.now() - t0.current)
        console.log(`${TAG} cold-load variant=${run.variant} rn_ms=${rnMs} dom_ms=${msg.domMs}`)
        setStatus(`cold-load ${run.variant}: ${rnMs} ms (dom ${msg.domMs} ms)`)
      }
    },
    [run],
  )

  const onLoadEnd = useCallback(() => {
    if (!run) return
    console.log(`${TAG} loadend variant=${run.variant} rn_ms=${Math.round(performance.now() - t0.current)}`)
  }, [run])

  const onWarmLoad = useCallback(() => {
    if (!run) return
    warmLoaded.current += 1
    console.log(`${TAG} warm-loaded idx=${warmLoaded.current}`)
    if (warmLoaded.current >= run.warm) {
      console.log(`${TAG} warm-ready count=${run.warm}`)
      setStatus((s) => `${s} · warm-ready ${run.warm}`)
    }
  }, [run])

  if (!run) {
    return (
      <View style={styles.menu}>
        <StatusBar style="auto" />
        <Text style={styles.title}>WebView spike (D11)</Text>
        <Text style={styles.sub}>{status}</Text>
        {[
          { label: 'Inline variant', variant: 'inline', warm: 0 },
          { label: 'File/baseUrl variant', variant: 'file', warm: 0 },
          { label: 'Inline + 3 warm WebViews', variant: 'inline', warm: 3 },
        ].map((opt) => (
          <Pressable
            key={opt.label}
            style={[styles.btn, opt.variant === 'file' && !fileUri && styles.btnDisabled]}
            disabled={opt.variant === 'file' && !fileUri}
            onPress={() => startRun({ variant: opt.variant, warm: opt.warm })}
          >
            <Text style={styles.btnText}>{opt.label}</Text>
          </Pressable>
        ))}
      </View>
    )
  }

  const mainSource =
    run.variant === 'file' ? { uri: fileUri } : { html: inlineHtml }

  return (
    <View style={styles.root}>
      <StatusBar style="auto" />
      {/* Warm WebViews: mounted, loaded, kept alive BEHIND the active one —
          "backgrounded, undestroyed" for the PSS axis. Always inline-sourced. */}
      {Array.from({ length: run.warm }, (_, i) => (
        <View key={`warm-${i}`} style={styles.warm} pointerEvents="none">
          <WebView
            originWhitelist={['*']}
            source={{ html: inlineHtml }}
            onLoadEnd={onWarmLoad}
          />
        </View>
      ))}
      {/* The measured WebView: full-screen, owns its own scroll. */}
      <WebView
        style={styles.web}
        originWhitelist={['*']}
        source={mainSource}
        allowFileAccess
        onMessage={onMessage}
        onLoadEnd={onLoadEnd}
      />
      <View style={styles.hud} pointerEvents="none">
        <Text style={styles.hudText}>
          {run.variant}
          {run.warm ? ` +${run.warm} warm` : ''} · {status}
        </Text>
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#fff' },
  web: { flex: 1 },
  warm: { ...StyleSheet.absoluteFillObject, zIndex: -1, opacity: 0 },
  menu: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12, padding: 24 },
  title: { fontSize: 20, fontWeight: '700' },
  sub: { fontSize: 13, color: '#555', marginBottom: 8 },
  btn: { backgroundColor: '#1d4ed8', paddingHorizontal: 20, paddingVertical: 12, borderRadius: 8 },
  btnDisabled: { opacity: 0.4 },
  btnText: { color: '#fff', fontWeight: '600' },
  hud: {
    position: 'absolute',
    top: 40,
    right: 8,
    backgroundColor: 'rgba(0,0,0,0.55)',
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  hudText: { color: '#fff', fontSize: 11 },
})
