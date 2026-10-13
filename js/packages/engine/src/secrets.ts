// The engine's two secrets: the private database's password and the admin token the
// first boot seeds. Both are generated on the first start of a dataDir and kept in
// <dataDir>/secrets.json, readable by the owner only, so a later start returns the
// same token without reseeding. The server's own keys are derived from the database
// password, so they are stable across boots and nothing else is stored.
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

export const SECRETS_FILE = 'secrets.json'

export interface EngineSecrets {
  pgPassword: string
  adminToken: string
}

const TOKEN = /^bp_admin_[A-Za-z0-9_-]{32}$/

export function generateSecrets(): EngineSecrets {
  return {
    pgPassword: crypto.randomBytes(32).toString('base64url'),
    // The shape Barkpark's clean seed and `bp setup` use: bp_admin_ + 24 random bytes.
    adminToken: 'bp_admin_' + crypto.randomBytes(24).toString('base64url'),
  }
}

/** Read the dataDir's secrets, or create them on its first start. */
export function loadOrCreateSecrets(dataDir: string): EngineSecrets & { created: boolean } {
  const file = path.join(dataDir, SECRETS_FILE)
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8')) as Partial<EngineSecrets>
    if (typeof value.pgPassword !== 'string' || value.pgPassword.length < 32 || typeof value.adminToken !== 'string' || !TOKEN.test(value.adminToken)) {
      throw new Error(`${file} is not a valid engine secrets file. Nothing was changed.`)
    }
    return { pgPassword: value.pgPassword, adminToken: value.adminToken, created: false }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  const secrets = generateSecrets()
  const temporary = `${file}.${process.pid}.tmp`
  fs.writeFileSync(temporary, JSON.stringify(secrets, null, 2) + '\n', { mode: 0o600 })
  fs.renameSync(temporary, file)
  return { ...secrets, created: true }
}

/** The keys a production release refuses to boot without, derived from the database password. */
export function releaseKeys(pgPassword: string): Record<string, string> {
  const derive = (label: string, bytes: number) =>
    Buffer.from(crypto.hkdfSync('sha256', Buffer.from(pgPassword), Buffer.from('barkpark-engine'), Buffer.from(label), bytes))
  return {
    SECRET_KEY_BASE: derive('secret-key-base', 48).toString('base64'),
    BARKPARK_CLOAK_KEY: derive('cloak', 32).toString('base64'),
    BARKPARK_KEK: derive('kek', 32).toString('base64'),
    PREVIEW_JWT_SECRET: derive('preview-jwt', 32).toString('hex'),
    BARKPARK_RELEASE_CAPTURE_HMAC_SECRET: derive('release-capture', 32).toString('hex'),
  }
}

/** Replace every secret in text with [redacted]. */
export function redactor(secrets: readonly string[]): (text: string) => string {
  const list = secrets.filter(s => s.length >= 8)
  return text => list.reduce((out, secret) => out.split(secret).join('[redacted]'), text)
}
