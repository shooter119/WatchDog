// Private server command; deliberately has no HTTP equivalent.
// node src/admin-initialize.js <existing-member-id>
process.env.WATCHDOG_DB_DRIVER = 'postgres';
const store = require('./postgres-store');
const { createAdminAuth } = require('./admin-auth');

async function main() {
  const memberId = process.argv[2];
  if (!memberId || process.argv.length !== 3) throw new Error('用法：node src/admin-initialize.js <已有成员ID>');
  await store.ready;
  await createAdminAuth(store).setGrant(null, memberId, 'platform_admin', { bootstrap: true });
  console.log('平台管理员已初始化');
}
main().catch((error) => { console.error(error.code || error.message); process.exitCode = 1; })
  .finally(() => store.close());
