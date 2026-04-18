export type PmName = 'pnpm' | 'npm' | 'yarn' | 'bun'

export interface PmInfo {
  name: PmName
  runCommand: string
  installCommand: string
  execCommand: string
}

const TABLE: Record<PmName, Omit<PmInfo, 'name'>> = {
  pnpm: { runCommand: 'pnpm', installCommand: 'pnpm install', execCommand: 'pnpm exec' },
  npm: { runCommand: 'npm run', installCommand: 'npm install', execCommand: 'npx' },
  yarn: { runCommand: 'yarn', installCommand: 'yarn', execCommand: 'yarn' },
  bun: { runCommand: 'bun run', installCommand: 'bun install', execCommand: 'bunx' },
}

export function detectPackageManager(): PmInfo {
  const name = sniff()
  return { name, ...TABLE[name] }
}

function sniff(): PmName {
  const ua = process.env.npm_config_user_agent ?? ''
  if (ua.startsWith('pnpm')) return 'pnpm'
  if (ua.startsWith('yarn')) return 'yarn'
  if (ua.startsWith('bun')) return 'bun'
  if (ua.startsWith('npm')) return 'npm'

  const execPath = process.env.npm_execpath ?? ''
  if (/pnpm/i.test(execPath)) return 'pnpm'
  if (/yarn/i.test(execPath)) return 'yarn'
  if (/bun/i.test(execPath)) return 'bun'

  return 'npm'
}
