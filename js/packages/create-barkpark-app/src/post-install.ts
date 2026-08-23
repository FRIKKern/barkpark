import { execa } from 'execa'
import { rm, stat } from 'node:fs/promises'
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
  // Whether a .git already existed BEFORE this run: a re-run inside an
  // existing repository must never have its history deleted by our cleanup.
  const gitDir = path.join(targetDir, '.git')
  const preexisting = await stat(gitDir).then(
    () => true,
    () => false,
  )
  try {
    await execa('git', ['init', '-q'], { cwd: targetDir })
    await execa('git', ['add', '-A'], { cwd: targetDir })
    await execa('git', ['commit', '-q', '-m', 'chore: initial commit from create-barkpark-app'], {
      cwd: targetDir,
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME || 'Barkpark',
        GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL || 'barkpark@example.com',
        GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME || 'Barkpark',
        GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL || 'barkpark@example.com',
      },
    })
  } catch (err) {
    // Still non-fatal — the scaffold is complete and usable without git — but
    // no longer SILENT, and no longer a strand: a failure mid-sequence (e.g. a
    // global commit.gpgsign with a broken signer) used to leave a
    // half-initialised .git (files staged, zero commits) and say nothing.
    // Mirror the dependency-install failure path: one yellow warning + the
    // manual recovery command, and remove the .git THIS run created
    // (create-next-app precedent). A pre-existing repository is left intact.
    const message = (err as Error).message.split('\n')[0]
    console.error(pc.yellow(`git init failed: ${message}`))
    console.error(
      pc.yellow(
        `Your project files are intact. Run "git init && git add -A && git commit" manually from ${targetDir}.`,
      ),
    )
    if (!preexisting) {
      await rm(gitDir, { recursive: true, force: true }).catch(() => {
        // Cleanup is best-effort; the warning above already told the user.
      })
    }
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
    lines.push(
      `  ${pc.cyan(`${opts.pm.runCommand} dev`)}    ${pc.dim('# uses hosted demo at https://barkpark.dev')}`,
    )
    lines.push('')
    lines.push(pc.yellow('You are on the public hosted demo dataset (read-only).'))
    lines.push(
      pc.dim('When you are ready for local data: re-run create-barkpark-app without --hosted-demo'),
    )
  } else {
    lines.push(
      `  ${pc.cyan('docker compose up -d')}        ${pc.dim('# Phoenix API + Postgres on :4000')}`,
    )
    lines.push(
      `  ${pc.cyan(`${opts.pm.runCommand} codegen`)}  ${pc.dim('# generate types from schema')}`,
    )
    lines.push(
      `  ${pc.cyan(`${opts.pm.runCommand} dev`)}                ${pc.dim('# Next.js on :3000')}`,
    )
  }
  lines.push('')
  lines.push(
    pc.dim(
      'Want a free hosted API for prototyping? Pass --hosted-demo. (Defaults to local docker-compose.)',
    ),
  )
  lines.push('')
  for (const line of lines) {
    console.log(line)
  }
}
