// Minimal token set for the skeleton. The Unified Aesthetic manifest is the
// eventual source of truth (one token manifest → per-surface output); until
// mobile joins that pipeline these mirror the evergreen neutrals so the
// skeleton doesn't invent a palette.
import { useColorScheme } from 'react-native'

export interface Theme {
  bg: string
  surface: string
  border: string
  text: string
  textMuted: string
  accent: string
  accentText: string
  danger: string
  success: string
  /** The user chat bubble — a soft neutral one step off the background
   * (the ChatGPT/Claude register: quiet gray, NOT the accent), read with
   * the normal text color. */
  bubble: string
  /** Which palette this is — REQUIRED so consumers stop sniffing hex
   * literals (MermaidIsland's `theme.bg !== '#f6f7f6'` was the live bug
   * this kills: retune the light background and dark detection breaks). */
  isDark: boolean
  /** Code panel — a step off the surface so code reads as a region. */
  codeBg: string
  /** Code foreground — near-text, tuned for the code panel. */
  codeFg: string
  /** Warning — the manifest's lifecycle.blocked family (role: warn). */
  warn: string
  /** Soft warning fill (chip/row background under `warn` content). */
  warnSoft: string
  /** Soft success fill (chip/row background under `success` content). */
  successSoft: string
  /** Soft danger fill (chip/row background under `danger` content). */
  dangerSoft: string
}

export const light: Theme = {
  bg: '#f6f7f6',
  surface: '#ffffff',
  border: '#e2e6e3',
  text: '#17211b',
  textMuted: '#5d6b62',
  accent: '#1f6f4a',
  accentText: '#ffffff',
  danger: '#b3372e',
  success: '#1f6f4a',
  bubble: '#e9ede9',
  isDark: false,
  codeBg: '#eef1ef',
  codeFg: '#233029',
  warn: '#d97706',
  warnSoft: '#f9f1e2',
  successSoft: '#e7f2ea',
  dangerSoft: '#f8e9e7',
}

export const dark: Theme = {
  bg: '#121714',
  surface: '#1b221e',
  border: '#2c352f',
  text: '#e8ede9',
  textMuted: '#93a198',
  accent: '#3fa374',
  accentText: '#0c110e',
  danger: '#e06c5f',
  success: '#3fa374',
  bubble: '#242d27',
  isDark: true,
  codeBg: '#161c19',
  codeFg: '#cfd9d2',
  warn: '#fbbf24',
  warnSoft: '#33290f',
  successSoft: '#1d2b23',
  dangerSoft: '#33211f',
}

export function useTheme(): Theme {
  return useColorScheme() === 'dark' ? dark : light
}
