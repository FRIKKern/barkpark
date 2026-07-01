/**
 * True median of a numeric sample. For an even-length input it averages the
 * two middle elements (rather than returning the upper one), so reported
 * benchmark latencies are not skewed toward the slower sample. Pure and
 * non-mutating — the input array is copied before sorting.
 */
export function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 === 0 ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[(n - 1) / 2];
}
