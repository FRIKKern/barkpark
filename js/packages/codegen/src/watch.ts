// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import chokidar from 'chokidar'

export interface WatchHandle {
  close: () => Promise<void>
}

export interface StartWatchOptions {
  debounceMs?: number
}

export function startWatch(
  path: string,
  onChange: () => void | Promise<void>,
  opts: StartWatchOptions = {},
): WatchHandle {
  const debounceMs = opts.debounceMs ?? 200
  const watcher = chokidar.watch(path, { ignoreInitial: true })
  let timer: NodeJS.Timeout | undefined

  const trigger = (): void => {
    if (timer !== undefined) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = undefined
      try {
        const out = onChange()
        if (out && typeof (out as Promise<void>).then === 'function') {
          ;(out as Promise<void>).catch((err: unknown) => {
            process.stderr.write(
              `watch: onChange rejected: ${(err as Error)?.stack ?? String(err)}\n`,
            )
          })
        }
      } catch (err) {
        process.stderr.write(
          `watch: onChange threw: ${(err as Error)?.stack ?? String(err)}\n`,
        )
      }
    }, debounceMs)
  }

  watcher.on('add', trigger)
  watcher.on('change', trigger)
  watcher.on('unlink', trigger)
  watcher.on('error', (err: unknown) => {
    process.stderr.write(`watch: ${(err as Error)?.message ?? String(err)}\n`)
  })

  return {
    close: async () => {
      if (timer !== undefined) {
        clearTimeout(timer)
        timer = undefined
      }
      await watcher.close()
    },
  }
}
