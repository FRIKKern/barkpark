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
}

const light: Theme = {
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
}

const dark: Theme = {
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
}

export function useTheme(): Theme {
  return useColorScheme() === 'dark' ? dark : light
}
