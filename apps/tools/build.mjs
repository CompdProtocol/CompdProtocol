import { copyFile, mkdir, rm, stat } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildDirectory, frontendFiles, sourceDirectory } from '../site.config.mjs';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceRoot = resolve(packageRoot, sourceDirectory);
const outputRoot = resolve(packageRoot, buildDirectory);
await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });
for (const relativeFile of frontendFiles) {
  const source = resolve(sourceRoot, relativeFile);
  if (!source.startsWith(sourceRoot + '/') && !source.startsWith(sourceRoot + '\\')) throw new Error('Unsafe frontend path: ' + relativeFile);
  if (!(await stat(source)).isFile()) throw new Error('Required frontend file is missing: ' + relativeFile);
  const destination = resolve(outputRoot, relativeFile);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination);
}
process.stdout.write('Built ' + frontendFiles.length + ' frontend files into ' + outputRoot + '\n');