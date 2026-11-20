/** Rejects with "<what> timed out after Ns" when `promise` has not settled in `ms`. */
export function limit(promise, ms, what) {
  let timer
  const late = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms / 1000}s`)), ms)
  })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}
