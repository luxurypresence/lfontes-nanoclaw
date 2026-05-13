import { execSync } from 'node:child_process';
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const SKILL_DIR = resolve(__dirname, '..');
const CONFIG_PATH = join(SKILL_DIR, 'upstream.json');

interface UpstreamEntry {
  repo: string;
  path: string;
  target: string;
  branch: string;
  commit: string | null;
}

type UpstreamConfig = Record<string, UpstreamEntry | null>;

function loadConfig(): UpstreamConfig {
  return JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
}

function saveConfig(config: UpstreamConfig): void {
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2) + '\n');
}

function getLatestCommit(repo: string, branch: string): string {
  const output = execSync(`git ls-remote https://github.com/${repo}.git refs/heads/${branch}`, {
    encoding: 'utf-8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const sha = output.split('\t')[0];
  if (!sha) throw new Error(`Could not resolve HEAD for ${repo}#${branch}`);
  return sha;
}

function shortSha(sha: string): string {
  return sha.slice(0, 7);
}

function checkEntry(name: string, entry: UpstreamEntry): { behind: boolean; local: string | null; remote: string } | null {
  if (entry.repo === 'TODO') {
    console.log(`  ${name}: skipped (upstream not configured)`);
    return null;
  }

  const remote = getLatestCommit(entry.repo, entry.branch);
  const local = entry.commit;

  if (local === remote) {
    console.log(`  ${name}: up to date (${shortSha(remote)})`);
    return { behind: false, local, remote };
  }

  if (local) {
    console.log(`  ${name}: behind (${shortSha(local)} -> ${shortSha(remote)})`);
  } else {
    console.log(`  ${name}: no commit tracked, latest is ${shortSha(remote)}`);
  }
  return { behind: true, local, remote };
}

function updateEntry(name: string, entry: UpstreamEntry, commitSha: string): void {
  const tmpDir = join(tmpdir(), `skill-update-${name}-${Date.now()}`);

  try {
    console.log(`  ${name}: cloning ${entry.repo}@${shortSha(commitSha)}...`);
    execSync(`git clone --depth 1 --branch ${entry.branch} https://github.com/${entry.repo}.git ${tmpDir}`, {
      stdio: 'pipe',
    });

    // Verify we got the expected commit
    const clonedSha = execSync('git rev-parse HEAD', { cwd: tmpDir, encoding: 'utf-8' }).trim();
    if (clonedSha !== commitSha) {
      console.log(`  ${name}: warning — expected ${shortSha(commitSha)} but cloned ${shortSha(clonedSha)}`);
    }

    const sourcePath = entry.path === '.' ? tmpDir : join(tmpDir, entry.path);
    if (!existsSync(sourcePath)) {
      console.error(`  ${name}: source path "${entry.path}" not found in repo`);
      return;
    }

    const targetPath = resolve(SKILL_DIR, entry.target);
    const targetParent = dirname(targetPath);

    if (!existsSync(targetParent)) {
      mkdirSync(targetParent, { recursive: true });
    }

    if (existsSync(targetPath)) {
      rmSync(targetPath, { recursive: true });
    }
    cpSync(sourcePath, targetPath, { recursive: true });

    // Clean up .git directory if we copied the repo root
    const copiedGitDir = join(targetPath, '.git');
    if (existsSync(copiedGitDir)) {
      rmSync(copiedGitDir, { recursive: true });
    }

    // For framework references: rename SKILL.md -> index.md to prevent standalone discovery
    const skillMdPath = join(targetPath, 'SKILL.md');
    const indexMdPath = join(targetPath, 'index.md');
    if (entry.target.includes('references/') && existsSync(skillMdPath) && !existsSync(indexMdPath)) {
      renameSync(skillMdPath, indexMdPath);
      console.log(`  ${name}: renamed SKILL.md -> index.md`);
    }

    console.log(`  ${name}: updated to ${shortSha(clonedSha)}`);
  } finally {
    if (existsSync(tmpDir)) {
      rmSync(tmpDir, { recursive: true });
    }
  }
}

function syncGraphQLSchema(): void {
  const fetchScript = join(SKILL_DIR, 'references', 'graphql-schema', 'scripts', 'fetch-schema.ts');

  if (!existsSync(fetchScript)) {
    console.error('  graphql-schema: fetch script not found');
    return;
  }

  console.log('  graphql-schema: fetching latest schemas...');
  try {
    execSync(`npx tsx ${fetchScript}`, { stdio: 'inherit' });
    console.log('  graphql-schema: schemas updated');
  } catch {
    console.error('  graphql-schema: fetch failed (auth key may need updating)');
  }
}

function printUsage(): void {
  console.log(`Usage: npx tsx update.ts [--check | --update]

  --check   Show which skills are behind their upstream (default)
  --update  Pull latest from all upstreams and save commit hashes
`);
}

async function main() {
  const args = process.argv.slice(2);
  const mode = args.includes('--update') ? 'update' : 'check';

  if (args.includes('--help') || args.includes('-h')) {
    printUsage();
    return;
  }

  const config = loadConfig();
  let hasUpdates = false;

  if (mode === 'check') {
    console.log('Checking upstreams...\n');

    for (const [name, entry] of Object.entries(config)) {
      if (entry === null) {
        if (name === 'graphql-schema') {
          console.log(`  ${name}: uses fetch script (run --update to refresh)`);
        } else {
          console.log(`  ${name}: no upstream`);
        }
        continue;
      }

      const result = checkEntry(name, entry);
      if (result?.behind) hasUpdates = true;
    }

    if (hasUpdates) {
      console.log('\nRun with --update to pull latest.');
    } else {
      console.log('\nAll up to date.');
    }
  } else {
    console.log('Updating upstreams...\n');

    for (const [name, entry] of Object.entries(config)) {
      if (entry === null) {
        if (name === 'graphql-schema') {
          syncGraphQLSchema();
        }
        continue;
      }

      if (entry.repo === 'TODO') {
        console.log(`  ${name}: skipped (upstream not configured)`);
        continue;
      }

      const remote = getLatestCommit(entry.repo, entry.branch);

      if (entry.commit === remote) {
        console.log(`  ${name}: already at ${shortSha(remote)}, skipping`);
        continue;
      }

      updateEntry(name, entry, remote);
      entry.commit = remote;
      hasUpdates = true;
    }

    if (hasUpdates) {
      saveConfig(config);
      console.log('\nupstream.json updated with new commit hashes.');
    } else {
      console.log('\nNothing to update.');
    }
  }
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
