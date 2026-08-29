const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`模型清单读取失败：${filePath}：${error.message}`);
  }
}

function validateManifestShape(manifest) {
  if (!manifest || manifest.schemaVersion !== 1 || typeof manifest.modelVersion !== 'string' ||
      !manifest.modelVersion || !manifest.files || typeof manifest.files !== 'object' ||
      Array.isArray(manifest.files) || Object.keys(manifest.files).length === 0) {
    throw new Error('模型清单字段无效');
  }
  for (const [relative, item] of Object.entries(manifest.files)) {
    if (!/^[A-Za-z0-9._/-]+$/.test(relative) || relative.startsWith('/') ||
        relative.split('/').some((part) => part === '..' || part === '')) {
      throw new Error(`模型清单包含不安全路径：${relative}`);
    }
    if (!item || !Number.isSafeInteger(item.sizeBytes) || item.sizeBytes <= 0 ||
        !/^[0-9a-f]{64}$/i.test(String(item.sha256 || ''))) {
      throw new Error(`模型清单文件项无效：${relative}`);
    }
  }
  return manifest;
}

function safeFilePath(rootDir, relative) {
  const root = path.resolve(rootDir);
  const resolved = path.resolve(root, relative);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    throw new Error(`模型路径越界：${relative}`);
  }
  return resolved;
}

function fileSha256(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function validateLocalManifest(manifestPath, rootDir) {
  const manifest = validateManifestShape(readJson(manifestPath));
  for (const [relative, item] of Object.entries(manifest.files)) {
    const filePath = safeFilePath(rootDir, relative);
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`模型文件不是普通文件：${relative}`);
    if (stat.size !== item.sizeBytes) throw new Error(`模型文件大小不匹配：${relative}`);
    if (fileSha256(filePath) !== String(item.sha256).toLowerCase()) {
      throw new Error(`模型文件 SHA-256 不匹配：${relative}`);
    }
  }
  return manifest;
}

function compareManifests(expected, actual) {
  validateManifestShape(actual);
  if (actual.schemaVersion !== expected.schemaVersion || actual.modelVersion !== expected.modelVersion) {
    throw new Error('线上模型清单版本不匹配');
  }
  const expectedFiles = Object.keys(expected.files).sort();
  const actualFiles = Object.keys(actual.files).sort();
  if (expectedFiles.join('\n') !== actualFiles.join('\n')) throw new Error('线上模型清单文件集合不匹配');
  for (const relative of expectedFiles) {
    const expectedItem = expected.files[relative];
    const actualItem = actual.files[relative];
    if (actualItem.sizeBytes !== expectedItem.sizeBytes ||
        String(actualItem.sha256).toLowerCase() !== String(expectedItem.sha256).toLowerCase()) {
      throw new Error(`线上模型清单文件项不匹配：${relative}`);
    }
  }
}

async function readStdin() {
  let data = '';
  for await (const chunk of process.stdin) data += chunk;
  return JSON.parse(data);
}

async function main(argv = process.argv.slice(2)) {
  const [mode, first, second] = argv;
  if (mode === 'local' && first && second) {
    const manifest = validateLocalManifest(first, second);
    console.log(`本地模型清单校验通过：${Object.keys(manifest.files).length} 个文件`);
    return;
  }
  if (mode === 'remote' && first) {
    const expected = validateManifestShape(readJson(first));
    const actual = await readStdin();
    compareManifests(expected, actual);
    console.log(`线上模型清单校验通过：${Object.keys(actual.files).length} 个文件`);
    return;
  }
  throw new Error('用法：verify-model-manifest.js local <manifest> <root> 或 remote <expected-manifest>');
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

module.exports = { validateManifestShape, validateLocalManifest, compareManifests };
