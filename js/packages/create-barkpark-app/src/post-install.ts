import { execa } from 'execa'
import path from 'node:path'
import pc from 'picocolors'
import type { PmInfo } from './pm.js'

export interface PostInstallOptions {
  targetDir: string
  projectName: string
  pm: PmInfo
  hostedDemo: boolean
  skipGit: boolean
  didInstall: boolean
}

export async function runGitInit(targetDir: string): Promise<void> {
  try {
    await execa('git', ['init', '-q'], { cwd: targetDir })
    await execa('git', ['add', '-A'], { cwd: targetDir })
    await execa(
      'git',
      ['commit', '-q', '-m', 'chore: initial commit from create-barkpark-app'],
      { cwd: targetDir, env: { ...process.env, GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME || 'Barkpark', GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL || 'barkpark@example.com', GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME || 'Barkpark', GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL || 'barkpark@example.com' } },
    )
  } catch {
    // non-fatal
  }
}

export function printNextSteps(opts: PostInstallOptions): void {
  const rel = path.relative(process.cwd(), opts.targetDir) || opts.projectName
  const lines: string[] = []
  lines.push('')
  lines.push(pc.bold('Next steps:'))
  lines.push(`  ${pc.cyan('cd')} ${rel}`)
  if (!opts.didInstall) {
    lines.push(`  ${pc.cyan(opts.pm.installCommand)}`)
  }
  if (opts.hostedDemo) {
    lines.push(`  ${pc.cyan(`${opts.pm.runCommand} dev`)}    ${pc.dim('# uses hosted demo at https://barkpark.dev')}`)
    lines.push('')
    lines.push(pc.yellow('You are on the public hosted demo dataset (read-only).'))
    lines.push(pc.dim('When you are ready for local data:'))
    lines.push(`  ${pc.cyan('npx barkpark demo eject')}    ${pc.dim('# swaps in docker-compose + local .env')}`)
  } else {
    lines.push(`  ${pc.cyan('docker compose up -d')}        ${pc.dim('# Phoenix API + Postgres on :4000')}`)
    lines.push(`  ${pc.cyan(`${opts.pm.runCommand} barkpark codegen`)}  ${pc.dim('# generate types from schema')}`)
    lines.push(`  ${pc.cyan(`${opts.pm.runCommand} dev`)}                ${pc.dim('# Next.js on :3000')}`)
  }
  lines.push('')
  lines.push(pc.dim('Want a free hosted API for prototyping? Pass --hosted-demo. (Defaults to local docker-compose.)'))
  lines.push('')
  for (const line of lines) {
    console.log(line)
  }
}
