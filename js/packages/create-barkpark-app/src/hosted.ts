import { promises as fs } from 'node:fs'
import path from 'node:path'
import pc from 'picocolors'
import { HOSTED_DEMO_URL } from './constants.js'

export interface HostedDemoOptions {
  targetDir: string
}

/**
 * `applyHostedDemo` with the strand removed (cca-backlog-hosted-demo-strand).
 *
 * REMEDY DECISION, recorded: a throw in applyHostedDemo happens AFTER the copy
 * finished — the target holds a COMPLETE, usable scaffold, and only the
 * hosted-demo post-configuration (.env.local, compose removal, banner) is
 * missing. Deleting that tree (the cleanupPartialScaffold remedy the wave-1
 * slice applies to a HALF-copied tree) would destroy finished work to fix a
 * config file the user can write by hand; and letting the throw escape (the
 * old behaviour) aborted the run and left ensureTargetEmpty refusing every
 * retry. So the remedy is to RELIEVE, not clean up: catch, say exactly what
 * failed, print the two manual steps that finish the hosted-demo setup, and
 * let the run continue (install, git, next steps all still apply). There is
 * nothing left to retry, so the retry jam cannot occur.
 *
 * Returns true when the settings applied, false when the user got the manual
 * fallback instead. Never throws.
 */
export async function applyHostedDemoSafely(opts: HostedDemoOptions): Promise<boolean> {
  try {
    await applyHostedDemo(opts)
    return true
  } catch (err) {
    console.error(pc.yellow(`Could not apply --hosted-demo settings: ${(err as Error).message}`))
    console.error(
      pc.yellow('Your scaffold is complete and usable. To finish pointing it at the hosted demo:'),
    )
    console.error(pc.yellow('  1. delete docker-compose.yml and docker-compose.override.yml.example'))
    console.error(
      pc.yellow(
        `  2. create .env.local containing:\n       BARKPARK_API_URL=${HOSTED_DEMO_URL}\n       BARKPARK_PROJECT=demo\n       BARKPARK_DATASET=production\n       BARKPARK_TOKEN=`,
      ),
    )
    return false
  }
}

export async function applyHostedDemo(opts: HostedDemoOptions): Promise<void> {
  const { targetDir } = opts

  await removeIfExists(path.join(targetDir, 'docker-compose.yml'))
  await removeIfExists(path.join(targetDir, 'docker-compose.override.yml.example'))

  const envPath = path.join(targetDir, '.env.local')
  const envContents = [
    `BARKPARK_API_URL=${HOSTED_DEMO_URL}`,
    'BARKPARK_PROJECT=demo',
    'BARKPARK_DATASET=production',
    'BARKPARK_TOKEN=',
    '',
  ].join('\n')
  await fs.writeFile(envPath, envContents, 'utf8')

  await enableHostedDemoBanner(targetDir)
}

async function removeIfExists(filePath: string): Promise<void> {
  try {
    await fs.rm(filePath, { force: true })
  } catch {
    // ignore
  }
}

async function enableHostedDemoBanner(targetDir: string): Promise<void> {
  const candidates = [
    path.join(targetDir, 'app', 'layout.tsx'),
    path.join(targetDir, 'src', 'app', 'layout.tsx'),
  ]
  for (const candidate of candidates) {
    try {
      const raw = await fs.readFile(candidate, 'utf8')
      if (raw.includes('HostedDemoBanner')) {
        const updated = raw.replace(
          /\{\s*\/\*\s*HOSTED_DEMO_BANNER_DISABLED\s*\*\/\s*\}/g,
          '<HostedDemoBanner />',
        )
        await fs.writeFile(candidate, updated, 'utf8')
        return
      }
    } catch {
      // try next candidate
    }
  }
}
