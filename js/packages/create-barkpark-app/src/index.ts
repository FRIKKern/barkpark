import { Command } from 'commander'
import path from 'node:path'
import * as p from '@clack/prompts'
import pc from 'picocolors'
import { AVAILABLE_TEMPLATES, BARKPARK_VERSION, type TemplateName } from './constants.js'
import { runPrompts } from './prompts.js'
import { scaffold } from './scaffold.js'
import { detectPackageManager } from './pm.js'
import { applyHostedDemoSafely } from './hosted.js'
import { runInstall } from './install.js'
import { printNextSteps, runGitInit } from './post-install.js'
import { cleanupPartialScaffold, ensureTargetEmpty } from './target-dir.js'

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
    .option(
      '--hosted-demo',
      'Opt into the hosted barkpark.dev demo instead of local docker-compose',
      false,
    )
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
  const targetState = await ensureTargetEmpty(targetDir)

  const pm = detectPackageManager()

  const s = p.spinner()
  s.start(
    `Scaffolding ${answers.template} → ${path.relative(process.cwd(), targetDir) || answers.projectName}`,
  )

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
    // Best-effort: clear the half-copied tree so the immediate retry is not
    // blocked by the not-empty guard. Never mask the original failure.
    await cleanupPartialScaffold(targetState).catch(() => {})
    return 1
  }
  s.stop(
    `Copied ${result.filesWritten} file${result.filesWritten === 1 ? '' : 's'} from templates/${answers.template}`,
  )

  if (result.empty) {
    console.log(
      pc.yellow(
        `Note: template "${answers.template}" is an empty placeholder in this build — W4.2/W4.3 will populate it.`,
      ),
    )
  }

  if (answers.hostedDemo) {
    const hs = p.spinner()
    hs.start('Applying --hosted-demo settings')
    // A throw here used to escape after the copy finished, aborting the run
    // and leaving a COMPLETE tree that jammed ensureTargetEmpty on every
    // retry. The remedy (recorded in applyHostedDemoSafely's doc) is relieve,
    // not delete: warn with the manual steps and continue — the scaffold is
    // usable and install/git/next-steps all still apply.
    const applied = await applyHostedDemoSafely({ targetDir })
    hs.stop(
      applied
        ? `Pointed at hosted demo: ${pc.cyan('https://barkpark.dev')} (read-only)`
        : 'Hosted-demo settings failed — manual steps printed above.',
    )
  }

  let didInstall = false
  let installFailed = false
  if (answers.install) {
    try {
      await runInstall({ targetDir, pm })
      didInstall = true
    } catch (err) {
      installFailed = true
      console.error(pc.yellow(`Dependency install failed: ${(err as Error).message}`))
      console.error(pc.yellow(`You can run "${pm.installCommand}" manually from ${targetDir}.`))
    }
  }

  if (answers.git) {
    await runGitInit(targetDir)
  }

  p.outro(installFailed ? pc.yellow('Done, with warnings.') : pc.green('Done.'))

  printNextSteps({
    targetDir,
    projectName: answers.projectName,
    pm,
    hostedDemo: answers.hostedDemo,
    skipGit: !answers.git,
    didInstall,
  })

  // DECISION (cca-backlog-install-exit-code): an install the USER ASKED FOR
  // that failed exits 1. Scripted use — `create-barkpark-app x -y && cd x &&
  // npm test` — must not sail on past a half-installed tree, and a green
  // "Done." would tonally contradict the yellow errors above. The scaffold
  // itself is finished, usable work: nothing is deleted, git init still ran,
  // and printNextSteps re-adds the manual install step for interactive users.
  return installFailed ? 1 : 0
}

main(process.argv)
  .then((code) => {
    process.exit(code)
  })
  .catch((err) => {
    console.error(pc.red((err as Error).message ?? String(err)))
    if (process.env.DEBUG) console.error((err as Error).stack)
    process.exit(1)
  })
