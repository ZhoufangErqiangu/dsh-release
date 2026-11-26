#!/usr/bin/env node
/**
 * Stage a source-independent production installation of DSH.
 *
 * The repository's own release path packs every workspace member in the
 * runtime closure to a tarball and installs those tarballs plus the pinned
 * registry versions of external dependencies into a fresh hoisted tree. This
 * script reuses that contract (see apps/cli/tests/profiles/packed-installation.ts)
 * so the Debian payload contains only runtime files and never the 2 GB
 * development node_modules or a symlink to the build machine's pnpm store.
 *
 * Environment:
 *   SRC_DIR      pinned source checkout (built)
 *   OUT_DIR      installation directory to create
 *   ARCHIVES_DIR scratch directory for the packed tarballs
 *   PNPM_BIN     pnpm executable
 *   STORE_DIR    pnpm store shared with the workspace install
 */

import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import {
  existsSync, globSync, mkdirSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, writeFileSync,
} from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'

const RUNTIME_SECTIONS = ['dependencies', 'optionalDependencies', 'peerDependencies']

function env(name) {
  const value = process.env[name]
  if (value === undefined || value === '') throw new Error(`${name} is required`)
  return value
}

const SRC = resolve(env('SRC_DIR'))
const OUT = resolve(env('OUT_DIR'))
const ARCHIVES = resolve(env('ARCHIVES_DIR'))
const PNPM = env('PNPM_BIN')
const STORE = resolve(env('STORE_DIR'))

const log = (...args) => console.error('  -', ...args)
const fail = (message) => { throw new Error(message) }

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'))
}

function dependencyEntries(manifest, section) {
  const value = manifest[section]
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return []
  return Object.entries(value).filter((entry) => typeof entry[1] === 'string')
}

function optionalPeer(manifest, name) {
  const metadata = manifest.peerDependenciesMeta
  if (metadata === null || typeof metadata !== 'object' || Array.isArray(metadata)) return false
  const entry = metadata[name]
  return entry !== null && typeof entry === 'object' && !Array.isArray(entry) && entry.optional === true
}

/** Follow workspace dependencies and required peers from one package. */
function packedWorkspaceClosure(rootName, packages) {
  const closure = []
  const visited = new Set()
  const visit = (name) => {
    if (visited.has(name)) return
    visited.add(name)
    const current = packages.get(name)
    if (current === undefined) fail(`packed workspace closure cannot resolve ${name}`)
    closure.push(current)
    for (const section of RUNTIME_SECTIONS) {
      for (const [dependency, range] of dependencyEntries(current.manifest, section)) {
        if (!range.startsWith('workspace:')) continue
        if (section === 'peerDependencies' && optionalPeer(current.manifest, dependency)) continue
        visit(dependency)
      }
    }
  }
  visit(rootName)
  return closure.sort((left, right) => left.directory.localeCompare(right.directory))
}

function supportsCurrentPlatform(manifest) {
  const os = manifest.os
  const cpu = manifest.cpu
  return (!Array.isArray(os) || os.includes(process.platform))
    && (!Array.isArray(cpu) || cpu.includes(process.arch))
}

function pnpm(args, cwd) {
  log(`pnpm ${args[0]} (${cwd === SRC ? 'source' : 'installation'})`)
  execFileSync(PNPM, args, {
    cwd,
    stdio: ['ignore', 'inherit', 'inherit'],
    env: {
      ...process.env,
      CI: '1',
      COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
    },
  })
}

function assertNoEscape(directory) {
  const installedRoot = realpathSync(directory)
  const visited = new Set()
  const visit = (path) => {
    const resolved = realpathSync(path)
    if (resolved !== installedRoot && !resolved.startsWith(installedRoot + sep)) {
      fail(`${path} escapes its installation (${resolved})`)
    }
    if (visited.has(resolved)) return
    visited.add(resolved)
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const child = join(path, entry.name)
      if (entry.isSymbolicLink()) {
        const target = existsSync(child) ? realpathSync(child) : resolve(dirname(child), readlinkSync(child))
        if (!target.startsWith(installedRoot + sep)) fail(`${child} escapes its installation (${target})`)
      } else if (entry.isDirectory()) {
        visit(child)
      }
    }
  }
  visit(directory)
}

function fileSpec(fromDirectory, target) {
  return `file:${relative(fromDirectory, target).split(sep).join('/')}`
}

// ── inventory ────────────────────────────────────────────────────────────────

const packages = new Map()
for (const pattern of ['apps/*/package.json', 'packages/*/*/package.json', 'vendor/*/package.json', 'native/system/packages/*/package.json']) {
  for (const path of globSync(pattern, { cwd: SRC })) {
    const directory = dirname(join(SRC, path))
    const manifest = readJson(join(SRC, path))
    if (typeof manifest.name !== 'string') fail(`${path} has no package name`)
    packages.set(manifest.name, { name: manifest.name, manifest, directory })
  }
}
if (!packages.has('@deepseek-ai/dsh')) fail('@deepseek-ai/dsh is missing from the workspace inventory')

const closure = packedWorkspaceClosure('@deepseek-ai/dsh', packages)
const runtimeMembers = closure.filter((member) => supportsCurrentPlatform(member.manifest))
const skipped = closure.filter((member) => !supportsCurrentPlatform(member.manifest))
const members = new Map(runtimeMembers.map((member) => [member.name, member]))
log(`runtime closure: ${closure.length} workspace packages (${runtimeMembers.length} for ${process.platform}/${process.arch})`)

// ── pack workspace members ───────────────────────────────────────────────────

rmSync(ARCHIVES, { recursive: true, force: true })
mkdirSync(ARCHIVES, { recursive: true })

pnpm([
  'pack', '--recursive', '--workspace-concurrency=4',
  ...[...members.keys()].map((name) => `--filter=${name}`),
  '--pack-destination', ARCHIVES,
], SRC)

const tarballs = new Map()
for (const member of members.values()) {
  if (typeof member.manifest.version !== 'string') fail(`${member.name} has no version`)
  const filename = `${member.name.replaceAll('/', '-').replace('@', '')}-${member.manifest.version}.tgz`
  const archive = join(ARCHIVES, filename)
  if (!existsSync(archive)) fail(`missing packed payload for ${member.name} (${archive})`)
  tarballs.set(member.name, archive)
}
log(`packed ${tarballs.size} tarballs`)

// ── resolve external versions exactly as the workspace installed them ───────

const requireFromSource = createRequire(join(SRC, 'package.json'))
let yaml
try {
  yaml = requireFromSource('js-yaml')
} catch {
  fail('js-yaml is not installed in the source checkout; run scripts/build-source.sh first')
}
const workspaceSettings = yaml.load(readFileSync(join(SRC, 'pnpm-workspace.yaml'), 'utf8')) ?? {}

const externalVersions = {}
for (const member of members.values()) {
  const memberRequire = createRequire(join(member.directory, 'package.json'))
  for (const section of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const [name, range] of dependencyEntries(member.manifest, section)) {
      if (range.startsWith('workspace:') || range.startsWith('link:') || range.startsWith('file:')) continue
      const manifestPath = (memberRequire.resolve.paths(name) ?? [])
        .map((path) => join(path, name, 'package.json'))
        .find((path) => existsSync(path))
      if (manifestPath === undefined) continue
      externalVersions[`${name}@${range}`] = readJson(manifestPath).version
    }
  }
}
log(`pinned ${Object.keys(externalVersions).length} external dependency ranges`)

// ── materialize a fresh hoisted installation ────────────────────────────────

rmSync(OUT, { recursive: true, force: true })
mkdirSync(OUT, { recursive: true })

const patchedDependencies = workspaceSettings.patchedDependencies ?? {}
for (const patchPath of Object.values(patchedDependencies)) {
  mkdirSync(dirname(join(OUT, patchPath)), { recursive: true })
  writeFileSync(join(OUT, patchPath), readFileSync(join(SRC, patchPath)))
}

const subprocessLocal = '@deepseek-ai/dsh-subprocess-local'
const subprocessArchive = tarballs.get(subprocessLocal)
const allowBuilds = { ...(workspaceSettings.allowBuilds ?? {}) }
if (subprocessArchive !== undefined) {
  // The workspace allowBuilds key names `file:packages/...`; the installed
  // dependency is named by its tarball path, so authorize that exact spec.
  allowBuilds[`${subprocessLocal}@${fileSpec(OUT, subprocessArchive)}`] = true
}

const workspaceOverrides = Object.fromEntries(
  Object.entries(workspaceSettings.overrides ?? {}).filter(([, value]) => (
    typeof value === 'string' && !value.startsWith('link:') && !value.startsWith('workspace:')
  )),
)

writeFileSync(join(OUT, 'package.json'), JSON.stringify({
  name: 'dsh-deb-runtime',
  private: true,
  description: `DSH ${process.env.DSH_VERSION ?? ''} production installation staged for the Debian package`,
  dependencies: Object.fromEntries(runtimeMembers.map((member) => [member.name, fileSpec(OUT, tarballs.get(member.name))])),
}, null, 2) + '\n')

writeFileSync(join(OUT, 'pnpm-workspace.yaml'), yaml.dump({
  packages: ['.'],
  nodeLinker: 'hoisted',
  autoInstallPeers: false,
  allowUnusedPatches: true,
  ignoredOptionalDependencies: skipped.map((member) => member.name),
  allowBuilds,
  patchedDependencies,
  minimumReleaseAgeExclude: workspaceSettings.minimumReleaseAgeExclude ?? [],
  overrides: {
    ...workspaceOverrides,
    ...externalVersions,
    ...Object.fromEntries(runtimeMembers.map((member) => [member.name, fileSpec(OUT, tarballs.get(member.name))])),
  },
}))

mkdirSync(STORE, { recursive: true })
pnpm(['install', '--prefer-offline', '--no-frozen-lockfile', `--store-dir=${STORE}`], OUT)
assertNoEscape(OUT)

// ── validate the payload the deb will actually execute ──────────────────────

const required = [
  'node_modules/@deepseek-ai/dsh/lib/bin.js',
  'node_modules/@deepseek-ai/dsh/package.json',
  'node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html',
  'node_modules/@deepseek-ai/dsh-web-app/lib/index.js',
]
for (const path of required) {
  if (!existsSync(join(OUT, path))) fail(`staged installation is missing ${path}`)
}

const binarySuffix = process.platform === 'linux' && process.arch === 'x64'
  ? 'linux-x64'
  : process.platform === 'linux' && process.arch === 'arm64' ? 'linux-arm64' : undefined
if (binarySuffix !== undefined) {
  const nativeRoot = join(OUT, 'node_modules', `@deepseek-ai/node-addon-system-${binarySuffix}`)
  if (!existsSync(join(nativeRoot, 'prebuilds.json'))) fail(`staged installation is missing the ${binarySuffix} native system package`)
  if (!existsSync(join(nativeRoot, 'bin', 'landlock-run'))) fail('staged installation is missing the Landlock launcher')
  if (!existsSync(join(nativeRoot, 'bin', 'glibc', 'system.node'))) fail('staged installation is missing the glibc Node-API addon')
}
if (!existsSync(join(OUT, 'node_modules', 'node-pty'))) fail('staged installation is missing node-pty')
if (!existsSync(join(OUT, 'node_modules', 'koffi'))) fail('staged installation is missing koffi')

const total = execFileSync('du', ['-sk', OUT], { encoding: 'utf8' }).split('\t')[0]
log(`staged installation ready: ${total} KiB at ${OUT}`)
