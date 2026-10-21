function entryError(code, message, current, status = 409) {
  return Object.assign(new Error(message), { code, status, current });
}
function checkEntryVersion(current, expected, { allowExited = false } = {}) {
  if (!current) throw entryError('ENTRY_NOT_FOUND', '记录不存在', null, 404);
  if (allowExited && current.exited_at != null) return;
  if (expected == null && process.env.WATCHDOG_ENTRY_VERSION_REQUIRED === '1') {
    throw entryError('CLIENT_UPGRADE_REQUIRED', '请升级 App 后再进行人员操作', current, 428);
  }
  if (expected != null && (!Number.isSafeInteger(Number(expected)) || Number(expected) < 1 || Number(expected) !== Number(current.version))) {
    throw entryError('VERSION_CONFLICT', '该人员记录已被其他设备修改，请核对后重新提交', current);
  }
  if (current.exited_at != null) throw entryError('ENTRY_EXITED', '该人员已出场，不能修改当前读数', current);
}
module.exports = { checkEntryVersion, entryError };
