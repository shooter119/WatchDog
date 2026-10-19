'use strict';
let csrf = '', timer, generation = 0, authGeneration = 0, workspaceView = 'sites';
const $ = (id) => document.getElementById(id);
function endSession() {
  authGeneration++; csrf = '';
  $('workspace').hidden = true; $('welcome').textContent = ''; $('identity').textContent = '';
  $('members').replaceChildren(); $('audit').replaceChildren(); $('site-manager')?.replaceChildren(); $('login').hidden = false;
  document.dispatchEvent(new Event('admin-ended'));
}
const authMessages = { ADMIN_FORBIDDEN: '当前成员没有有效后台授权', ADMIN_SESSION_INVALID: '后台会话已失效，请重新扫码登录', ADMIN_CSRF_INVALID: '登录校验已失效，请刷新页面后重试', ADMIN_LAST_PLATFORM: '不能撤销最后一名有效平台管理员', ADMIN_MEMBER_INVALID: '成员状态或单位角色不满足授权条件', ADMIN_RATE_LIMITED: '请求过于频繁，请稍后重试' };
async function api(path, body, method = 'POST', poll = false) {
  const epoch = authGeneration;
  const response = await fetch(`/api/admin${path}`, { method, credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf, ...(poll ? { 'X-Admin-Poll': '1' } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const result = await response.json();
  if (epoch !== authGeneration) throw new Error('后台会话已失效，请重新扫码登录');
  if (!response.ok) {
    if (response.status === 401) endSession();
    throw new Error(authMessages[result.code] || result.error || '请求失败');
  }
  return result;
}
function showMember(member) {
  $('login').hidden = true; $('workspace').hidden = false;
  $('welcome').textContent = `你好，${member.real_name}`;
  $('identity').textContent = `${member.unit_name || ''} · ${member.admin_role === 'platform_admin' ? '平台管理员' : '单位后台管理员'}`;
  $('show-permissions').hidden = member.admin_role !== 'platform_admin';
  $('platform').hidden = member.admin_role !== 'platform_admin' || workspaceView !== 'access';
  document.dispatchEvent(new CustomEvent('admin-ready', { detail: member }));
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
$('show-sites').onclick = () => { workspaceView = 'sites'; $('platform').hidden = true; if ($('site-manager')) $('site-manager').hidden = false; };
$('show-permissions').onclick = () => { workspaceView = 'access'; $('platform').hidden = false; if ($('site-manager')) $('site-manager').hidden = true; };
function textNode(tag, value) { const node = document.createElement(tag); node.textContent = value; return node; }
$('load-members').onclick = async () => {
  try {
    const result = await api('/members', undefined, 'GET');
    $('members').replaceChildren();
    for (const member of result.members) {
      const row = document.createElement('div'); row.className = 'member-row';
      row.append(textNode('p', `${member.real_name} · ${member.unit_name} · 单位角色：${({ member: '成员', manager: '单位管理人员', admin: '单位管理员' })[member.unit_role] || '成员'}`));
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
    const actions = { admin_initialized: '平台管理员初始化', grant_set: '更新后台授权', grant_revoked: '撤销后台授权', login_confirmed: '确认网页登录', login_cancelled: '取消网页登录', login: '后台登录', logout: '退出当前会话', logout_all: '退出全部会话', key_site_created: '新建重点单位', key_site_updated: '更新单位档案', key_site_owner_changed: '调整维护归属', key_site_disabled: '停用单位', key_site_enabled: '恢复单位', key_site_draft_saved: '保存资料草稿', key_site_draft_discarded: '放弃资料草稿', key_site_published: '发布资料版本', key_site_uploaded: '上传资料附件', key_site_task_retried: '重试处理任务' };
    for (const event of result.events) $('audit').append(textNode('p', `${new Date(Number(event.created_at)).toLocaleString()} · ${actions[event.action] || '资料管理操作'} · 操作者 ${event.actor_name || '服务器私有初始化'}`));
  } catch (error) { $('error').textContent = error.message; }
};
setInterval(async () => {
  if ($('workspace').hidden) return;
  try { const result = await api('/me', undefined, 'GET'); csrf = result.csrf; showMember(result.member); }
  catch (error) {
    endSession();
    $('error').textContent = '后台会话已失效，请重新扫码登录';
  }
}, 10000);
api('/me', undefined, 'GET').then((result) => {
  csrf = result.csrf; showMember(result.member);
}).catch(() => refresh());
