export type ShapeNode =
  | { text: string }
  | { tag: string; classes: string[]; attrs: Record<string, string>; style: Record<string, string>; children: ShapeNode[] }

export interface GoldenCase {
  type: string
  input: Record<string, unknown>
  expectedHtml: string
  shape: unknown[]
}

export type Verdict = string[] | { diff: string[]; via: string } | typeof MISSING | typeof UNCHECKED

export interface Row {
  type: string
  via?: string
  status: 'pass' | 'fail' | 'missing' | 'unchecked'
  diff?: string[]
}

export interface Report {
  renderer: string
  compare: 'dom' | 'text'
  pack_stamp: string
  ran_at_sha: string
  rows: Row[]
}

export interface ConformOptions {
  renderer: string
  compare: 'dom' | 'text'
  judge: (golden: GoldenCase) => Verdict | Promise<Verdict>
  pack?: string
}

export const HERE: string
export const PACK: string
export const MISSING: unique symbol
export const UNCHECKED: unique symbol
export function loadPack(dir?: string): { stamp: string; cases: GoldenCase[] }
export function packStamp(dir?: string): string
export function shapeOf(nodes: ArrayLike<unknown>): ShapeNode[]
export function diffShapes(actual: ShapeNode[], golden: ShapeNode[]): string[]
export function htmlText(html: string): string
export function goldenWords(shape: unknown[]): string[]
export function diffWords(actualText: string, expected: string[]): string[] | typeof UNCHECKED
export function conform(options: ConformOptions): Promise<Report>
export function reportPath(renderer: string): string
export function settle(report: Report, options?: { write?: boolean; strict?: boolean; path?: string }): string[]
export function counts(report: Report): { pass: number; fail: number; missing: number; unchecked: number }
export function modeFromEnv(env?: Record<string, string | undefined>): { write: boolean; strict: boolean }
export function cli(options: ConformOptions): Promise<void>
