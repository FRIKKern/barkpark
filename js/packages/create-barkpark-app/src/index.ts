import { Command } from 'commander'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import * as p from '@clack/prompts'
import pc from 'picocolors'
import { AVAILABLE_TEMPLATES, BARKPARK_VERSION, type TemplateName } from './constants.js'
import { runPrompts } from './prompts.js'
import { scaffold } from './scaffold.js'
import { detectPackageManager } from './pm.js'
import { applyHostedDemo } from './hosted.js'
import { runInstall } from './install.js'
import { printNextSteps, runGitInit } from './post-install.js'

interface CliFlags {
  template?: string
  hostedDemo?: boolean
  yes?: boolean
  skipInstall?: boolean
  skipGit?: boolean
}

async function main(argv: string[]): Promise<number> {
  const program = new Command()
    .name('create-barkpark-app')
    .description('Scaffold a new Barkpark-powered app.')
    .argument('[directory]', 'Target directory (and project name) for the new app')
    .option('-t, --template <name>', `Template to use (${AVAILABLE_TEMPLATES.join(' | ')})`)
    .option('--hosted-demo', 'Opt into the hosted barkpark.dev demo instead of local docker-compose', false)
    .option('-y, --yes', 'Accept all defaults, no interactive prompts', false)
    .option('--skip-install', 'Skip running the package manager install step', false)
    .option('--skip-git', 'Skip git init + initial commit', false)
    .version(BARKPARK_VERSION, '-v, --version', 'Print CLI version')
    .helpOption('-h, --help', 'Show help')

  program.parse(argv)

  const rawDir = program.args[0]
  const flags = program.opts<CliFlags>()

  const templateArg = flags.template
  if (templateArg && !AVAILABLE_TEMPLATES.includes(templateArg as TemplateName)) {
    console.error(
      pc.red(`Unknown template "${templateArg}". Available: ${AVAILABLE_TEMPLATES.join(', ')}`),
    )
    return 1
  }

  const answers = await runPrompts({
    targetArg: rawDir,
    templateArg: templateArg as TemplateName | undefined,
    hostedDemoFlag: Boolean(flags.hostedDemo),
    yesFlag: Boolean(flags.yes),
    skipInstall: Boolean(flags.skipInstall),
    skipGit: Boolean(flags.skipGit),
  })

  const targetDir = path.resolve(process.cwd(), answers.projectName)
  await ensureTargetEmpty(targetDir)

  const pm = detectPackageManager()

  const s = p.spinner()
  s.start(`Scaffolding ${answers.template} → ${path.relative(process.cwd(), targetDir) || answers.projectName}`)

  let result
  try {
    result = await scaffold({
      template: answers.template,
      targetDir,
      projectName: answers.projectName,
      pmCommand: pm.runCommand,
    })
  } catch (err) {
    s.stop('Scaffold failed.')
    console.error(pc.red((err as Error).message))
    return 1
  }
  s.stop(`Copied ${result.filesWritten} file${result.filesWritten === 1 ? '' : 's'} from templates/${answers.template}`)

  if (result.empty) {
    console.log(pc.yellow(`Note: template "${answers.template}" is an empty placeholder in this build — W4.2/W4.3 will populate it.`))
  }

  if (answers.hostedDemo) {
    const hs = p.spinner()
    hs.start('Applying --hosted-demo settings')
    await applyHostedDemo({ targetDir })
    hs.stop(`Pointed at hosted demo: ${pc.cyan('https://barkpark.dev')} (read-only)`)
  }

  let didInstall = false
  if (answers.install) {
    try {
      await runInstall({ targetDir, pm })
      didInstall = true
    } catch (err) {
      console.error(pc.yellow(`Dependency install failed: ${(err as Error).message}`))
      console.error(pc.yellow(`You can run "${pm.installCommand}" manually from ${targetDir}.`))
    }
  }

  if (answers.git) {
    await runGitInit(targetDir)
  }

  p.outro(pc.green('Done.'))

  printNextSteps({
    targetDir,
    projectName: answers.projectName,
    pm,
    hostedDemo: answers.hostedDemo,
    skipGit: !answers.git,
    didInstall,
  })

  return 0
}

async function ensureTargetEmpty(targetDir: string): Promise<void> {
  try {
    const entries = await fs.readdir(targetDir)
    if (entries.length > 0) {
      throw new Error(`Target directory "${targetDir}" is not empty.`)
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code
    if (code === 'ENOENT') return
    if (code === 'ENOTDIR') throw new Error(`Target path "${targetDir}" exists and is not a directory.`)
    throw err
  }
}

main(process.argv)
  .then((code) => {
    process.exit(code)
  })
  .catch((err) => {
    console.error(pc.red((err as Error).stack ?? String(err)))
    process.exit(1)
  })
