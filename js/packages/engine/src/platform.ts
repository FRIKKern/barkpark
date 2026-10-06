// What differs between POSIX and Windows when the engine runs its programs: program
// names, the environment a child gets, how a release script is launched, how a process
// tree is stopped and how a process's start time is read. Everything else in the
// launcher is the same on every platform.
//
// The Windows half is written against the documented behaviour of Node, cmd.exe,
// taskkill and PowerShell; the engine-release workflow's Windows jobs are what run it.
import { execFileSync } from 'node:child_process'
import path from 'node:path'

const POSIX_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'

export const isWindows = (platform: string = process.platform) => platform === 'win32'

/** A program file name: `postgres` on POSIX, `postgres.exe` on Windows. */
export function exe(name: string, platform: string = process.platform): string {
  return isWindows(platform) ? `${name}.exe` : name
}

/** The release launcher inside an engine folder: bin/barkpark, or bin/barkpark.bat on Windows. */
export function releaseScript(root: string, platform: string = process.platform): string {
  return path.join(root, 'bin', isWindows(platform) ? 'barkpark.bat' : 'barkpark')
}

/**
 * The base environment for every child: a fixed system PATH and nothing from the
 * host's shell. Windows programs also need SystemRoot (Winsock and the C runtime
 * fail without it) and a temp folder.
 */
export function systemEnv(platform: string = process.platform, host: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  if (!isWindows(platform)) return { PATH: POSIX_PATH }
  const root = host.SystemRoot || host.SYSTEMROOT || 'C:\\Windows'
  const temp = host.TEMP || host.TMP || path.win32.join(root, 'Temp')
  return {
    PATH: [`${root}\\System32`, root, `${root}\\System32\\Wbem`].join(';'),
    SystemRoot: root, WINDIR: root, COMSPEC: host.COMSPEC || `${root}\\System32\\cmd.exe`, TEMP: temp, TMP: temp,
  }
}

/** Locale variables for Postgres and the release. Windows takes its locale from the system. */
export function localeEnv(platform: string = process.platform): NodeJS.ProcessEnv {
  if (isWindows(platform)) return {}
  const locale = platform === 'darwin' ? 'en_US.UTF-8' : 'C.UTF-8'
  return { LANG: locale, LC_ALL: locale }
}

/** initdb's --locale: a UTF-8 locale on POSIX, C on Windows (whose locale names differ). */
export function initdbLocale(platform: string = process.platform): string {
  return isWindows(platform) ? 'C' : platform === 'darwin' ? 'en_US.UTF-8' : 'C.UTF-8'
}

export interface Launch {
  file: string
  args: string[]
  windowsVerbatimArguments?: boolean
}

/**
 * How to start `file args`. Node refuses to run a .bat or .cmd file directly
 * (CVE-2024-27980), so on Windows a script runs under cmd.exe with every argument
 * quoted. An argument holding a double quote cannot be quoted for cmd.exe and is refused.
 */
export function launch(file: string, args: string[], platform: string = process.platform, host: NodeJS.ProcessEnv = process.env): Launch {
  if (!isWindows(platform) || !/\.(bat|cmd)$/i.test(file)) return { file, args }
  for (const arg of [file, ...args]) {
    if (arg.includes('"')) throw new Error(`Cannot pass ${JSON.stringify(arg)} to a Windows script: it contains a double quote.`)
  }
  const line = [file, ...args].map(arg => `"${arg}"`).join(' ')
  return { file: host.COMSPEC || 'cmd.exe', args: ['/d', '/s', '/c', `"${line}"`], windowsVerbatimArguments: true }
}

/** When a process started, as text that changes if the id is reused; '' when it is not running. */
export function processStartedAt(pid: number, platform: string = process.platform): string {
  try {
    if (isWindows(platform)) {
      return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `(Get-Process -Id ${pid}).StartTime.ToUniversalTime().ToString('o')`], {
        encoding: 'utf8', timeout: 15_000, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true,
      }).trim()
    }
    return execFileSync('ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', timeout: 15_000, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return ''
  }
}

/**
 * Ask a process tree to stop, or force it. POSIX signals the process group the
 * server leads (it is spawned detached). Windows has no groups or SIGTERM: taskkill
 * /T walks the tree from the pid, and /F forces it.
 */
export function signalTree(pid: number, force: boolean, platform: string = process.platform): void {
  if (isWindows(platform)) {
    try {
      execFileSync('taskkill.exe', ['/PID', String(pid), '/T', ...(force ? ['/F'] : [])], { stdio: 'ignore', timeout: 15_000, windowsHide: true })
    } catch {
      // taskkill exits non-zero when the process is already gone; the caller checks liveness.
    }
    return
  }
  try {
    process.kill(-pid, force ? 'SIGKILL' : 'SIGTERM')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error
  }
}
