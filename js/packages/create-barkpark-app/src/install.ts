import { execa } from 'execa'
import type { PmInfo } from './pm.js'

export interface InstallOptions {
  targetDir: string
  pm: PmInfo
}

export async function runInstall(opts: InstallOptions): Promise<void> {
  const [bin, ...args] = opts.pm.installCommand.split(' ')
  if (!bin) throw new Error('No package manager binary resolved.')
  await execa(bin, args, { cwd: opts.targetDir, stdio: 'inherit' })
}
