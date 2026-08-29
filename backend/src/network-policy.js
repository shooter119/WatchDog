const net = require('node:net');

/**
 * 出站请求的主机白名单工具。
 * 只接受主机名或“主机名:端口”，不接受 URL、路径、通配符或凭据。
 */
function parseAllowedHosts(value) {
  const raw = String(value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  const hosts = [];
  for (const item of raw) {
    if (item.includes('*')) {
      throw new Error('出站主机允许列表不支持通配符');
    }
    let parsed;
    try {
      parsed = new URL(`https://${item}`);
    } catch (_) {
      throw new Error('出站主机允许列表包含无效主机');
    }
    if (
      parsed.username ||
      parsed.password ||
      parsed.pathname !== '/' ||
      parsed.search ||
      parsed.hash ||
      parsed.hostname !== item.split(':')[0].toLowerCase() ||
      net.isIP(parsed.hostname) ||
      parsed.hostname === 'localhost' ||
      parsed.hostname.endsWith('.localhost')
    ) {
      throw new Error('出站主机允许列表只允许主机名或主机名:端口');
    }
    const normalized = parsed.host.toLowerCase();
    if (!hosts.includes(normalized)) hosts.push(normalized);
  }
  return hosts;
}

function isHostAllowed(url, allowedHosts) {
  const hostname = String(url.hostname || '').toLowerCase();
  const host = String(url.host || '').toLowerCase();
  return allowedHosts.some((allowed) => allowed === hostname || allowed === host);
}

module.exports = { parseAllowedHosts, isHostAllowed };
