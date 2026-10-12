import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const upstream = resolve(root, 'node_modules/@zereight/mcp-gitlab');
const expectedHash = '1d8e1a935d53edc56662bfcc5221e5a1092cf50310150eea5591e52810f27fd4';
const expectedBuildHash = 'e7ea88fd36b9dfa8d0c4abaa008f00a465fd5e78e2de1a479848ce0c68f0c77f';
const expectedDependencyHash = 'e3bdf63f0c1ffd287ad6e8c0c2f22a19ed97346c93489dde55787aefe6c7d095';
const marker = 'export const GitLabMergeRequestSchema = z.object({\n';
const addition = `    head_pipeline: GitLabPipelineSchema.pick({
        id: true, project_id: true, sha: true, ref: true,
        source: true, status: true, web_url: true,
    }).nullable().optional(),\n`;

export function treeDigest(directory, skipLockMetadata = false, replacements = new Map()) {
  if (!lstatSync(directory).isDirectory()) throw new Error('Artifact root must be a real directory');
  const canonical = realpathSync(directory);
  const entries = [];
  const visit = path => {
    const name = relative(directory, path).split(sep).join('/');
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) {
      const target = realpathSync(path);
      if (!target.startsWith(canonical + sep)) throw new Error('External dependency symlink rejected');
      entries.push([name, 'link', readlinkSync(path)]);
    } else if (stat.isDirectory()) {
      entries.push([name, 'directory']);
      for (const child of readdirSync(path).sort()) visit(resolve(path, child));
    } else if (stat.isFile()) {
      if (skipLockMetadata && name === '.package-lock.json') return;
      entries.push([name, 'file', stat.mode & 0o111, createHash('sha256').update(replacements.get(name) ?? readFileSync(path)).digest('hex')]);
    } else {
      throw new Error('Special artifact file rejected');
    }
  };
  visit(directory);
  return createHash('sha256').update(JSON.stringify(entries)).digest('hex');
}

export function prepare(output = resolve(root, '.generated-guard-v3')) {
  output = resolve(output);
  if (!output.startsWith(realpathSync(root) + sep) || realpathSync(dirname(output)) !== dirname(output)) {
    throw new Error('Provider output must have a canonical parent inside the integration directory');
  }
  if (existsSync(output) && !lstatSync(output).isDirectory()) {
    throw new Error('Provider output root must be a real directory');
  }
  const version = JSON.parse(readFileSync(resolve(upstream, 'package.json'), 'utf8')).version;
  const original = readFileSync(resolve(upstream, 'build/schemas.js'), 'utf8');
  const buildHash = treeDigest(resolve(upstream, 'build'));
  const dependencyHash = treeDigest(resolve(root, 'node_modules'), true);
  if (version !== '2.1.68' || createHash('sha256').update(original).digest('hex') !== expectedHash ||
      buildHash !== expectedBuildHash || dependencyHash !== expectedDependencyHash) {
    throw new Error('GitLab provider version/source mismatch; refusing an unreviewed patch');
  }
  const patched = original
    .replace(marker, marker + addition)
    .replace('    draft: z.coerce.boolean().optional(),', '    draft: z.boolean().optional(),')
    .replace('    allow_failure: z.coerce.boolean().optional(),', '    allow_failure: z.boolean().optional(),');
  const digest = createHash('sha256').update(patched).digest('hex');
  const patchedBuildHash = treeDigest(resolve(upstream, 'build'), false, new Map([['schemas.js', patched]]));
  const receipt = { version, patch_version: 3, upstream_schema_sha256: expectedHash, patched_schema_sha256: digest, upstream_build_sha256: buildHash, dependency_tree_sha256: dependencyHash, generated_build_sha256: patchedBuildHash };
  if (existsSync(output)) {
    const previous = JSON.parse(readFileSync(resolve(output, 'receipt.json'), 'utf8'));
    const observed = createHash('sha256').update(readFileSync(resolve(output, 'build/schemas.js'))).digest('hex');
    if (JSON.stringify(previous) !== JSON.stringify(receipt) || observed !== digest ||
        treeDigest(resolve(output, 'build')) !== patchedBuildHash) {
      throw new Error('Existing provider artifact differs; refusing overwrite');
    }
    return resolve(output, 'build/index.js');
  }
  mkdirSync(output, { recursive: false });
  cpSync(resolve(upstream, 'build'), resolve(output, 'build'), { recursive: true });
  writeFileSync(resolve(output, 'build/schemas.js'), patched);
  if (treeDigest(resolve(output, 'build')) !== patchedBuildHash) throw new Error('Generated provider tree differs');
  writeFileSync(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  return resolve(output, 'build/index.js');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify({ entrypoint: prepare() }));
}
