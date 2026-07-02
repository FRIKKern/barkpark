import { describe, it, expect, afterEach } from 'vitest'
import { toPackageName, renderTemplate } from '../src/scaffold'
import { normalizeProjectName, projectNameError } from '../src/prompts'
import { detectPackageManager } from '../src/pm'

describe('toPackageName', () => {
  it('lowercases and slugifies spaces/punctuation', () => {
    expect(toPackageName('My Cool Site')).toBe('my-cool-site')
    expect(toPackageName('Hello World!!!')).toBe('hello-world')
    expect(toPackageName('@scope/pkg')).toBe('scope-pkg')
  })

  it('strips a leading dot or underscore (npm forbids them)', () => {
    expect(toPackageName('.hidden')).toBe('hidden')
    expect(toPackageName('_private')).toBe('private')
  })

  it('collapses hyphen runs and trims leading/trailing hyphens', () => {
    expect(toPackageName('a---b')).toBe('a-b')
    expect(toPackageName('-edgy-')).toBe('edgy')
    expect(toPackageName('café')).toBe('caf') // non-ascii → '-' → trimmed
  })

  it('preserves interior underscores and dots (both npm-legal)', () => {
    expect(toPackageName('foo_bar.baz')).toBe('foo_bar.baz')
  })

  it('falls back to barkpark-site when nothing survives', () => {
    expect(toPackageName('   ')).toBe('barkpark-site')
    expect(toPackageName('!!!')).toBe('barkpark-site')
    expect(toPackageName('')).toBe('barkpark-site')
  })
})

describe('renderTemplate', () => {
  it('substitutes {{ key }} with optional surrounding whitespace', () => {
    expect(renderTemplate('Hi {{name}}', { name: 'Bo' })).toBe('Hi Bo')
    expect(renderTemplate('{{ a }}-{{  b  }}', { a: '1', b: '2' })).toBe('1-2')
  })

  it('leaves unknown placeholders intact (normalized, no inner spaces)', () => {
    expect(renderTemplate('{{missing}}', {})).toBe('{{missing}}')
    expect(renderTemplate('{{ missing }}', {})).toBe('{{missing}}')
  })

  it('does not leak inherited Object props (hasOwnProperty guard)', () => {
    // 'toString' exists on Object.prototype but not as an own key of {}
    expect(renderTemplate('{{toString}}', {})).toBe('{{toString}}')
  })

  it('replaces every occurrence', () => {
    expect(renderTemplate('{{x}}{{x}}{{x}}', { x: 'ab' })).toBe('ababab')
  })

  it('substitutes an empty-string value', () => {
    expect(renderTemplate('a{{gap}}b', { gap: '' })).toBe('ab')
  })
})

describe('normalizeProjectName', () => {
  it('trims and reduces a path to its basename', () => {
    expect(normalizeProjectName('  my-app  ')).toBe('my-app')
    expect(normalizeProjectName('./my-app')).toBe('my-app')
    expect(normalizeProjectName('foo/bar/baz')).toBe('baz')
    expect(normalizeProjectName('/abs/path/proj')).toBe('proj')
  })
})

describe('detectPackageManager', () => {
  const saved = {
    ua: process.env.npm_config_user_agent,
    exec: process.env.npm_execpath,
  }
  afterEach(() => {
    // Restore so one case can't bleed into the next (or the rest of the suite).
    if (saved.ua === undefined) delete process.env.npm_config_user_agent
    else process.env.npm_config_user_agent = saved.ua
    if (saved.exec === undefined) delete process.env.npm_execpath
    else process.env.npm_execpath = saved.exec
  })

  const setEnv = (ua?: string, exec?: string) => {
    if (ua === undefined) delete process.env.npm_config_user_agent
    else process.env.npm_config_user_agent = ua
    if (exec === undefined) delete process.env.npm_execpath
    else process.env.npm_execpath = exec
  }

  it('reads the user-agent prefix', () => {
    setEnv('pnpm/9.1.0 npm/? node/v22')
    expect(detectPackageManager().name).toBe('pnpm')
    setEnv('yarn/1.22.0')
    expect(detectPackageManager().name).toBe('yarn')
    setEnv('bun/1.0.0')
    expect(detectPackageManager().name).toBe('bun')
    setEnv('npm/10.0.0')
    expect(detectPackageManager().name).toBe('npm')
  })

  it('falls back to npm_execpath when the user-agent is absent', () => {
    setEnv(undefined, '/opt/homebrew/bin/yarn.js')
    expect(detectPackageManager().name).toBe('yarn')
  })

  it('defaults to npm when nothing identifies the manager', () => {
    setEnv(undefined, undefined)
    expect(detectPackageManager().name).toBe('npm')
  })

  it('returns the command table for the detected manager', () => {
    setEnv('pnpm/9.0.0')
    expect(detectPackageManager()).toEqual({
      name: 'pnpm',
      runCommand: 'pnpm',
      installCommand: 'pnpm install',
      execCommand: 'pnpm exec',
    })
  })
})

describe('projectNameError (non-interactive name validation)', () => {
  it('rejects names that normalize to empty (/, whitespace, empty)', () => {
    expect(projectNameError('/')).toMatch(/non-empty/)
    expect(projectNameError('   ')).toMatch(/non-empty/)
    expect(projectNameError('')).toMatch(/non-empty/)
  })

  it('rejects dot-leading names (., ..)', () => {
    expect(projectNameError('.')).toMatch(/may not start with/)
    expect(projectNameError('..')).toMatch(/may not start with/)
  })

  it('accepts valid names, including path-y args whose basename is valid', () => {
    expect(projectNameError('my-site')).toBeUndefined()
    expect(projectNameError('My App')).toBeUndefined()
    expect(projectNameError('./my-site')).toBeUndefined()
    expect(projectNameError('my-site/')).toBeUndefined()
  })
})
