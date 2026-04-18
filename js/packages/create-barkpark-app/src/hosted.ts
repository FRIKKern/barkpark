import { promises as fs } from 'node:fs'
import path from 'node:path'
import { HOSTED_DEMO_URL } from './constants.js'

export interface HostedDemoOptions {
  targetDir: string
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
        const updated = raw.replace(/\{\s*\/\*\s*HOSTED_DEMO_BANNER_DISABLED\s*\*\/\s*\}/g, '<HostedDemoBanner />')
        await fs.writeFile(candidate, updated, 'utf8')
        return
      }
    } catch {
      // try next candidate
    }
  }
}
