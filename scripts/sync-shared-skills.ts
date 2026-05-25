/**
 * sync-shared-skills — copy curated skill dirs from lfontes-mono into
 * `container/skills/` so they get picked up by the standard skill loader.
 *
 * Two source roots, merged into one dest dir:
 *   - $HOME/lfontes-mono/skills/        — Luis-cross-cutting skills
 *   - $HOME/lfontes-mono/clanq/skills/  — Clanq/nanoclaw-infra skills
 *
 * A skill name may appear in only one source root; collisions are an error.
 * Source-of-truth lives in lfontes-mono; nanoclaw holds disposable copies.
 *
 * Usage:
 *   pnpm tsx scripts/sync-shared-skills.ts
 *   pnpm tsx scripts/sync-shared-skills.ts --skills navigator,gh-cli
 *
 * Deletions: the script tracks what it synced in `.lfontes-mono-synced.json`
 * inside the dest dir. On re-run, any skill in that manifest that is no
 * longer present in any source root gets deleted from `container/skills/`.
 * With `--skills`, only the listed skills are considered for sync OR
 * deletion; manifest entries outside the filter pass through untouched.
 */
import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
function flag(name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

const sourceRoots = [
  path.resolve(path.join(os.homedir(), 'lfontes-mono', 'skills')),
  path.resolve(path.join(os.homedir(), 'lfontes-mono', 'clanq', 'skills')),
];
const dest = path.resolve(__dirname, '..', 'container', 'skills');
const onlyList = flag('skills')?.split(',').map((s) => s.trim()).filter(Boolean);

for (const root of sourceRoots) {
  if (!fs.existsSync(root)) {
    console.error(`source dir does not exist: ${root}`);
    process.exit(1);
  }
}
fs.mkdirSync(dest, { recursive: true });

const manifestPath = path.join(dest, '.lfontes-mono-synced.json');
type Manifest = { skills: string[]; files: string[] };
function readManifest(): Manifest {
  if (!fs.existsSync(manifestPath)) return { skills: [], files: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    return {
      skills: Array.isArray(parsed?.skills) ? parsed.skills : [],
      files: Array.isArray(parsed?.files) ? parsed.files : [],
    };
  } catch {
    return { skills: [], files: [] };
  }
}
const prevManifest = readManifest();
const prevDirs = new Set(prevManifest.skills);
const prevFiles = new Set(prevManifest.files);

// Build a merged view of all source roots. A name may live in only one root —
// collisions are an error (silent override would mask the user's intent).
const skillSourceRoot = new Map<string, string>();
const fileSourceRoot = new Map<string, string>();
for (const root of sourceRoots) {
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    const bucket = e.isDirectory() ? skillSourceRoot : e.isFile() ? fileSourceRoot : null;
    if (!bucket) continue;
    const prev = bucket.get(e.name);
    if (prev) {
      console.error(`collision: "${e.name}" exists in both ${prev} and ${root}`);
      process.exit(1);
    }
    bucket.set(e.name, root);
  }
}
const sourceDirs = new Set(skillSourceRoot.keys());
const sourceFiles = new Set(fileSourceRoot.keys());

// Dir candidates the script will touch on this run.
// - No filter: every source dir + every previously-synced dir (so deletions propagate).
// - With filter: only the listed names.
const dirCandidates = onlyList
  ? new Set(onlyList)
  : new Set<string>([...sourceDirs, ...prevDirs]);

let copiedDirs = 0;
let deletedDirs = 0;
const nextDirs = new Set<string>(prevDirs);

for (const name of dirCandidates) {
  const dst = path.join(dest, name);
  if (sourceDirs.has(name)) {
    const src = path.join(skillSourceRoot.get(name)!, name);
    // rsync handles incremental + delete-inside + exclude cleanly.
    execFileSync('rsync', ['-a', '--delete', '--exclude=last-check.json', `${src}/`, `${dst}/`], {
      stdio: 'inherit',
    });
    copiedDirs++;
    nextDirs.add(name);
  } else if (prevDirs.has(name)) {
    // Was synced previously, gone from source now — remove from dest.
    if (fs.existsSync(dst)) {
      fs.rmSync(dst, { recursive: true, force: true });
      console.log(`removed ${path.relative(path.resolve(__dirname, '..'), dst)} (no longer in source)`);
      deletedDirs++;
    }
    nextDirs.delete(name);
  }
  // else: filter named a skill that's neither in source nor manifest — silently skip.
}

// Top-level files: full-sync only (--skills targets dirs, leaves files alone).
let copiedFiles = 0;
let deletedFiles = 0;
const nextFiles = new Set<string>(prevFiles);

if (!onlyList) {
  const fileCandidates = new Set<string>([...sourceFiles, ...prevFiles]);
  for (const name of fileCandidates) {
    const dst = path.join(dest, name);
    if (sourceFiles.has(name)) {
      fs.copyFileSync(path.join(fileSourceRoot.get(name)!, name), dst);
      copiedFiles++;
      nextFiles.add(name);
    } else if (prevFiles.has(name)) {
      if (fs.existsSync(dst)) {
        fs.rmSync(dst, { force: true });
        console.log(`removed ${path.relative(path.resolve(__dirname, '..'), dst)} (no longer in source)`);
        deletedFiles++;
      }
      nextFiles.delete(name);
    }
  }
}

fs.writeFileSync(
  manifestPath,
  JSON.stringify(
    { skills: Array.from(nextDirs).sort(), files: Array.from(nextFiles).sort() },
    null,
    2,
  ) + '\n',
);

console.log(
  `synced ${copiedDirs} skill dir(s) (-${deletedDirs}), ${copiedFiles} top-level file(s) (-${deletedFiles}) — ${sourceRoots.join(' + ')} → ${dest}`,
);
console.log('next: ./container/build.sh + restart service to roll into running containers');
