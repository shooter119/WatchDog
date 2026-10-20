// Private deployment helper. The stream URL is read from stdin so it does not
// appear in shell history, source control, or process arguments.
const { createVideoResources } = require('./video-resources');

async function main() {
  const [unitId, name, description = ''] = process.argv.slice(2);
  if (!unitId || !name) {
    throw new Error(
      '用法：node src/video-resource-initialize.js <单位ID> <资源名称> [说明]，视频地址从标准输入读取',
    );
  }
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const streamUrl = Buffer.concat(chunks).toString('utf8').trim();
  if (!streamUrl) throw new Error('标准输入中没有视频地址');
  const store = require('./postgres-store');
  await store.ready;
  try {
    const resource = await createVideoResources(store).initialize(unitId, {
      name,
      description,
      streamUrl,
    });
    console.log(`视频资源已写入：${resource.name}（${resource.id}）`);
  } finally {
    await store.close();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
