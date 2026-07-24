#!/usr/bin/env bash
# Shared helpers for the D11 measurement scripts. SPIKE ARTIFACT, not product code.
set -euo pipefail

PKG=cloud.barkpark.webviewspike
SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$SPIKE_DIR/results"
mkdir -p "$RESULTS"

require_device() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "FATAL: adb not on PATH (install Android platform-tools)" >&2
    exit 1
  fi
  local n
  n=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "FATAL: no Android device/emulator attached (adb devices is empty)" >&2
    exit 1
  fi
}

# launch <variant> <warm> — cold-start the app straight into a run via deep link.
launch() {
  adb shell am force-stop "$PKG"
  sleep 1
  adb logcat -c
  adb shell am start -W -a android.intent.action.VIEW \
    -d "bpspike://run?variant=$1\&warm=$2" "$PKG" >/dev/null
}

# wait_for_log <grep-pattern> [timeout-s] — poll logcat until the pattern lands;
# prints the LAST matching line. Portable (no `timeout` on stock macOS).
wait_for_log() {
  local pattern=$1 timeout=${2:-30} i line
  for i in $(seq 1 $((timeout * 2))); do
    line=$(adb logcat -d 2>/dev/null | grep -E "$pattern" | tail -1 || true)
    if [ -n "$line" ]; then
      echo "$line"
      return 0
    fi
    sleep 0.5
  done
  echo "TIMEOUT waiting for: $pattern" >&2
  return 1
}

# Provider-agnostic WebView version: dumpsys webviewupdate names whatever
# provider is CURRENT (Google WebView, Chrome, vendor forks); fall back to the
# Google package probe only if that fails (review F3).
webview_version() {
  local v
  v=$(adb shell dumpsys webviewupdate 2>/dev/null | grep -m1 -E 'Current WebView package' | sed 's/^[[:space:]]*//' | tr -d '\r' || true)
  if [ -z "$v" ]; then
    v=$(adb shell dumpsys package com.google.android.webview 2>/dev/null | grep -m1 versionName | tr -d '\r ' || true)
  fi
  echo "$v"
}

device_info() {
  # Emulator detection must check BOTH qemu props: newer emulator images set
  # ro.boot.qemu and may leave ro.kernel.qemu blank (review F1). The lead
  # stamps the binding verdict off this field — a false "real hardware" here
  # would launder an advisory run.
  local qemu_kernel qemu_boot emulator build
  qemu_kernel=$(adb shell getprop ro.kernel.qemu | tr -d '\r')
  qemu_boot=$(adb shell getprop ro.boot.qemu | tr -d '\r')
  emulator=0
  if [ "$qemu_kernel" = "1" ] || [ "$qemu_boot" = "1" ]; then emulator=1; fi

  # Debug-vs-release auto-detection (review F4): a DEBUGGABLE APK skews every
  # axis, so the run is marked advisory and we warn loudly.
  build=release
  if adb shell dumpsys package "$PKG" 2>/dev/null | grep -q 'DEBUGGABLE'; then build=debug; fi
  if [ "$build" = "debug" ]; then
    echo "WARNING: installed APK is DEBUGGABLE — this run is ADVISORY ONLY." >&2
    echo "         Rebuild for the binding verdict: npx expo run:android --variant release" >&2
  fi

  {
    echo "model=$(adb shell getprop ro.product.model | tr -d '\r')"
    echo "device=$(adb shell getprop ro.product.device | tr -d '\r')"
    echo "android=$(adb shell getprop ro.build.version.release | tr -d '\r')"
    echo "sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
    echo "webview=$(webview_version)"
    echo "emulator=$emulator"
    echo "build=$build"
  } > "$RESULTS/device.txt"
  cat "$RESULTS/device.txt"
}
