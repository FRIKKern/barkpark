import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { exe, initdbLocale, launch, localeEnv, releaseScript, systemEnv } from '../src/platform'
import { resolveRelease, PROGRAMS } from '../src/release'

describe('platform: program names and the release script', () => {
  it('adds .exe on Windows only', () => {
    expect(exe('pg_ctl', 'win32')).toBe('pg_ctl.exe')
    expect(exe('pg_ctl', 'linux')).toBe('pg_ctl')
    expect(exe('pg_ctl', 'darwin')).toBe('pg_ctl')
  })

  it('runs bin/barkpark.bat on Windows and bin/barkpark elsewhere', () => {
    expect(releaseScript('/e', 'linux')).toBe(path.join('/e', 'bin', 'barkpark'))
    expect(releaseScript('/e', 'win32')).toBe(path.join('/e', 'bin', 'barkpark.bat'))
  })
})

describe('platform: the child environment', () => {
  it('is a fixed system PATH on POSIX, nothing from the host', () => {
    expect(systemEnv('linux', { PATH: '/home/me/bin', SECRET: 'x' })).toEqual({ PATH: '/usr/bin:/bin:/usr/sbin:/sbin' })
  })

  it('carries SystemRoot, a system PATH and a temp folder on Windows', () => {
    const env = systemEnv('win32', { SystemRoot: 'C:\\Windows', TEMP: 'C:\\T', PATH: 'C:\\evil', SECRET: 'x' })
    expect(env).toMatchObject({ SystemRoot: 'C:\\Windows', WINDIR: 'C:\\Windows', TEMP: 'C:\\T', TMP: 'C:\\T' })
    expect(env.PATH).toBe('C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\Wbem')
    expect(env.SECRET).toBeUndefined()
  })

  it('sets a UTF-8 locale on POSIX and leaves Windows to its system locale', () => {
    expect(localeEnv('linux')).toEqual({ LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8' })
    expect(localeEnv('darwin')).toEqual({ LANG: 'en_US.UTF-8', LC_ALL: 'en_US.UTF-8' })
    expect(localeEnv('win32')).toEqual({})
    expect(initdbLocale('win32')).toBe('C')
  })
})

describe('platform: launching a release script', () => {
  it('runs a program directly everywhere, and a POSIX script directly', () => {
    expect(launch('/e/bin/barkpark', ['eval', 'X.y()'], 'linux')).toEqual({ file: '/e/bin/barkpark', args: ['eval', 'X.y()'] })
    expect(launch('C:\\pg\\bin\\initdb.exe', ['-D', 'C:\\d'], 'win32')).toEqual({ file: 'C:\\pg\\bin\\initdb.exe', args: ['-D', 'C:\\d'] })
  })

  it('runs a .bat under cmd.exe with every argument quoted, verbatim', () => {
    const l = launch('C:\\Program Files\\app\\bin\\barkpark.bat', ['eval', 'Barkpark.Release.migrate()'], 'win32', { COMSPEC: 'C:\\Windows\\System32\\cmd.exe' })
    expect(l).toEqual({
      file: 'C:\\Windows\\System32\\cmd.exe',
      args: ['/d', '/s', '/c', '""C:\\Program Files\\app\\bin\\barkpark.bat" "eval" "Barkpark.Release.migrate()""'],
      windowsVerbatimArguments: true,
    })
  })

  it('refuses an argument cmd.exe cannot quote', () => {
    expect(() => launch('C:\\e\\bin\\barkpark.bat', ['eval', 'IO.puts("x")'], 'win32')).toThrow(/double quote/)
  })
})

describe('resolveRelease on Windows', () => {
  const winRelease = () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'engine-win-'))
    fs.mkdirSync(path.join(root, 'bin'))
    fs.mkdirSync(path.join(root, 'releases'))
    fs.writeFileSync(path.join(root, 'bin', 'barkpark.bat'), '')
    fs.mkdirSync(path.join(root, 'postgres', 'bin'), { recursive: true })
    for (const name of PROGRAMS) fs.writeFileSync(path.join(root, 'postgres', 'bin', `${name}.exe`), '')
    fs.writeFileSync(path.join(root, 'engine.json'), JSON.stringify({ version: 1, commit: 'b'.repeat(40), platform: 'win32', arch: 'x64', postgres: { version: '15.18', extensions: [], programs: [...PROGRAMS] } }))
    return root
  }

  it('accepts a Windows engine folder: barkpark.bat and the .exe programs', () => {
    const root = winRelease()
    expect(resolveRelease(root, { platform: 'win32', arch: 'x64' })).toMatchObject({ root, bin: path.join(root, 'bin', 'barkpark.bat') })
  })

  it('names the win32-x64 platform package when none is installed', () => {
    const none = () => { throw new Error('not found') }
    expect(() => resolveRelease(null, { platform: 'win32', arch: 'x64' }, none)).toThrow(/@barkpark\/engine-win32-x64 is not installed/)
  })
})
