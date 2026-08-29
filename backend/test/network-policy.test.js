const { test } = require('node:test');
const assert = require('node:assert/strict');

const { parseAllowedHosts, isHostAllowed } = require('../src/network-policy');

test('出站主机白名单只匹配登记的主机或主机端口', () => {
  const allowed = parseAllowedHosts('api.deepseek.com, proxy.example:8443');
  assert.equal(isHostAllowed(new URL('https://api.deepseek.com/chat'), allowed), true);
  assert.equal(isHostAllowed(new URL('https://api.deepseek.com:9443/chat'), allowed), true);
  assert.equal(isHostAllowed(new URL('https://proxy.example:8443/chat'), allowed), true);
  assert.equal(isHostAllowed(new URL('https://proxy.example:9444/chat'), allowed), false);
  assert.equal(isHostAllowed(new URL('https://evil.example/chat'), allowed), false);
});

test('出站主机白名单拒绝 URL、通配符、路径和 IP/本机目标', () => {
  for (const value of [
    '*.example.com',
    'https://example.com',
    'example.com/path',
    '127.0.0.1',
    'localhost',
  ]) {
    assert.throws(() => parseAllowedHosts(value));
  }
});
