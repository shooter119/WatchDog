'use strict';
let csrf = '', timer, generation = 0;
const $ = (id) => document.getElementById(id);
async function api(path, body, method = 'POST') {
  const response = await fetch(`/api/admin${path}`, { method, credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.code || '请求失败');
  return result;
}
function showMember(member) {
  $('login').hidden = true; $('workspace').hidden = false;
  $('welcome').textContent = `你好，${member.real_name}`;
  $('identity').textContent = member.admin_role === 'platform_admin' ? '平台管理员' : '单位后台管理员';
  $('platform').hidden = member.admin_role !== 'platform_admin';
}
async function refresh() {
  const current = ++generation;
  clearTimeout(timer); $('error').textContent = ''; $('qr').replaceChildren();
  $('login-state').textContent = '正在生成二维码…';
  try {
    const challenge = await api('/login/challenges', {});
    if (current !== generation) return;
    const image = new Image(); image.src = challenge.qrImage; image.alt = '用火场智控 App 扫描登录';
    $('qr').replaceChildren(image); $('login-state').textContent = '等待 App 扫码确认';
    async function poll() {
      if (current !== generation) return;
      if (Date.now() >= challenge.expiresAt) {
        $('qr').replaceChildren(); $('login-state').textContent = '二维码已过期，请刷新'; return;
      }
      try {
        const result = await api('/login/claim', { id: challenge.id });
        if (current !== generation) return;
        if (result.member) { csrf = result.csrf; showMember(result.member); return; }
        timer = setTimeout(poll, 2000);
      } catch (error) { $('qr').replaceChildren(); $('login-state').textContent = '登录已取消或失效，请刷新'; }
    }
    timer = setTimeout(poll, 2000);
  } catch (error) { $('login-state').textContent = '二维码加载失败，请重试'; $('error').textContent = error.message; }
}
async function logout(all) {
  try { await api('/logout', { all }); location.reload(); }
  catch (error) { $('error').textContent = error.message; }
}
$('refresh').onclick = refresh;
$('logout').onclick = () => logout(false);
$('logout-all').onclick = () => logout(true);
function textNode(tag, value) { const node = document.createElement(tag); node.textContent = value; return node; }
$('load-members').onclick = async () => {
  try {
    const result = await api('/members', undefined, 'GET');
    $('members').replaceChildren();
    for (const member of result.members) {
      const row = document.createElement('div'); row.className = 'member-row';
      row.append(textNode('p', `${member.real_name} · ${member.unit_name} · 单位角色：${member.unit_role}`));
      const select = document.createElement('select'); select.setAttribute('aria-label', `${member.real_name}的后台授权`);
      for (const [value, label] of [['', '无后台授权'], ['unit_admin', '单位后台管理员'], ['platform_admin', '平台管理员']]) {
        const option = textNode('option', label); option.value = value; select.append(option);
      }
      select.value = member.admin_role || '';
      const button = textNode('button', '保存授权');
      button.onclick = async () => {
        if (!confirm(`确认将 ${member.unit_name} 的 ${member.real_name} 设置为“${select.selectedOptions[0].textContent}”？`)) return;
        try { await api(`/grants/${encodeURIComponent(member.id)}`, { role: select.value || null }, 'PUT'); $('error').textContent = '授权已更新'; }
        catch (error) { $('error').textContent = error.message; }
      };
      row.append(select, button); $('members').append(row);
    }
  } catch (error) { $('error').textContent = error.message; }
};
$('load-audit').onclick = async () => {
  try {
    const result = await api('/audit', undefined, 'GET'); $('audit').replaceChildren();
    for (const event of result.events) $('audit').append(textNode('p', `${new Date(Number(event.created_at)).toLocaleString()} · ${event.action} · 操作者 ${event.actor_id || '私有初始化'} · ${event.target_id || ''}`));
  } catch (error) { $('error').textContent = error.message; }
};
setInterval(async () => {
  if ($('workspace').hidden) return;
  try { const result = await api('/me', undefined, 'GET'); csrf = result.csrf; showMember(result.member); }
  catch (error) {
    csrf = ''; $('workspace').hidden = true; $('welcome').textContent = ''; $('identity').textContent = '';
    $('members').replaceChildren(); $('audit').replaceChildren(); $('login').hidden = false;
    $('error').textContent = '后台会话已失效，请重新扫码登录';
  }
}, 10000);
api('/me', undefined, 'GET').then((result) => {
  csrf = result.csrf; showMember(result.member);
}).catch(() => refresh());
