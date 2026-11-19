import { $, createAsyncButton, el, encodePath, formatDate } from '../../core/dom.js';
import { apiRequest } from '../../core/api.js';
import { toast } from '../../ui/toast.js';

const ACTION_LABELS = {
  login: ['登录后台', 'pill-safe'],
  login_confirmed: ['扫码确认', 'pill-info'],
  login_cancelled: ['取消扫码', 'pill-neutral'],
  logout: ['退出会话', 'pill-neutral'],
  logout_all: ['全部下线', 'pill-caution'],
  grant_set: ['变更授权', 'pill-info'],
  grant_revoked: ['撤销授权', 'pill-danger'],
  admin_initialized: ['初始化平台管理员', 'pill-safe'],
  hazmat_created: ['新增危化品', 'pill-safe'],
  hazmat_updated: ['更新危化品', 'pill-info'],
  hazmat_deleted: ['删除危化品', 'pill-danger'],
  hazmat_imported: ['批量导入危化品', 'pill-info'],
};

const UNIT_ROLE_LABELS = {
  admin: '单位负责人',
  manager: '骨干管理员',
  member: '普通成员',
};

const ADMIN_ROLE_LABELS = {
  platform_admin: '平台管理员',
  unit_admin: '单位资料管理员',
};

export function createAccessView() {
  let mounted = false;
  let unitsLoaded = false;
  let membersAbort = null;
  let auditAbort = null;
  let selectedUnitId = '';

  let unitSelect = null;
  let membersBox = null;
  let auditBox = null;

  function mount() {
    const container = $('platform');
    if (!container || mounted) return;
    mounted = true;

    unitSelect = el(
      'select',
      {
        id: 'member-unit',
        className: 'select-sm',
        onChange: () => {
          selectedUnitId = unitSelect.value;
          loadMembers();
        },
      },
      el('option', { value: '' }, '全部组织'),
    );

    const refreshMembersBtn = createAsyncButton('刷新成员列表', 'btn btn-secondary btn-sm', () => loadMembers());
    const refreshAuditBtn = createAsyncButton('刷新审计日志', 'btn btn-subtle btn-sm', () => loadAudit());

    membersBox = el('div', { id: 'members', className: 'members-grid' });
    auditBox = el('div', { id: 'audit', className: 'audit-stream' });

    const grantPanel = el(
      'div',
      { className: 'panel-section' },
      el(
        'div',
        { className: 'section-head' },
        el(
          'div',
          null,
          el('h2', null, '后台授权管理'),
          el('p', { className: 'muted' }, '单位管理角色与独立后台授权分离。开通前请核实指战员姓名及所属单位。'),
        ),
        el(
          'div',
          { className: 'toolbar-actions' },
          el('label', { className: 'inline-filter' }, el('span', null, '所属单位'), unitSelect),
          refreshMembersBtn,
        ),
      ),
      membersBox,
    );

    const auditPanel = el(
      'div',
      { className: 'panel-section' },
      el(
        'div',
        { className: 'section-head' },
        el(
          'div',
          null,
          el('h2', null, '管理操作审计'),
          el('p', { className: 'muted' }, '不可篡改的后台关键授权、登录与数据变更日志（最新 100 条）。'),
        ),
        refreshAuditBtn,
      ),
      auditBox,
    );

    container.replaceChildren(grantPanel, auditPanel);
  }

  async function ensureUnits() {
    if (unitsLoaded || !unitSelect) return;
    try {
      const { data } = await apiRequest('/units');
      const units = data.units || [];
      unitSelect.replaceChildren(
        el('option', { value: '' }, '全部组织'),
        ...units.map((u) => el('option', { value: u.id }, u.name)),
      );
      unitSelect.value = selectedUnitId;
      unitsLoaded = true;
    } catch (err) {
      if (err?.name !== 'AbortError') {
        toast.error(err?.message || '组织列表加载失败');
      }
    }
  }

  async function loadMembers() {
    if (!membersBox) return;
    membersAbort?.abort();
    membersAbort = new AbortController();
    membersBox.replaceChildren(
      el('div', { className: 'skeleton-list' }, el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' })),
    );

    try {
      await ensureUnits();
      const qs = selectedUnitId ? `?unit_id=${encodeURIComponent(selectedUnitId)}` : '';
      const { data } = await apiRequest(`/members${qs}`, { signal: membersAbort.signal });
      const members = data.members || [];
      if (!members.length) {
        membersBox.replaceChildren(
          el('div', { className: 'empty-state' }, el('strong', null, '暂无符合条件的成员'), el('span', null, '切换所属单位或确认成员已通过入队审批')),
        );
        return;
      }

      membersBox.replaceChildren(
        ...members.map((m) => {
          const canUnitAdmin = ['manager', 'admin'].includes(m.unit_role);
          const roleSelect = el(
            'select',
            { className: 'select-sm', 'aria-label': `${m.real_name} 的后台权限` },
            el('option', { value: '' }, '无后台权限'),
            canUnitAdmin || m.admin_role === 'unit_admin'
              ? el('option', { value: 'unit_admin' }, '单位资料管理员')
              : null,
            el('option', { value: 'platform_admin' }, '平台管理员'),
          );
          roleSelect.value = m.admin_role || '';

          const saveBtn = createAsyncButton('保存授权', 'btn btn-primary btn-xs', async () => {
            try {
              await apiRequest(`/grants/${encodePath(m.id)}`, {
                method: 'PUT',
                body: { role: roleSelect.value || null },
              });
              toast.success(`已更新「${m.real_name}」的后台权限`);
              await Promise.all([loadMembers(), loadAudit()]);
            } catch (err) {
              toast.error(err?.message || '保存权限失败');
            }
          });

          const roleBadge = m.admin_role
            ? el('span', { className: m.admin_role === 'platform_admin' ? 'pill pill-info' : 'pill pill-safe' }, ADMIN_ROLE_LABELS[m.admin_role] || m.admin_role)
            : el('span', { className: 'pill pill-neutral' }, '未授权');

          return el(
            'article',
            { className: 'member-card' },
            el(
              'div',
              { className: 'member-info' },
              el('div', { className: 'member-name-row' }, el('strong', null, m.real_name || '未命名成员'), roleBadge),
              el('span', { className: 'muted', style: { fontSize: '12px' } }, `${m.unit_name || '未知单位'} · ${UNIT_ROLE_LABELS[m.unit_role] || m.unit_role || '成员'}`),
            ),
            el('div', { className: 'member-actions' }, roleSelect, saveBtn),
          );
        }),
      );
    } catch (err) {
      if (err?.name === 'AbortError') return;
      membersBox.replaceChildren(el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '加载成员列表失败'));
    }
  }

  async function loadAudit() {
    if (!auditBox) return;
    auditAbort?.abort();
    auditAbort = new AbortController();
    auditBox.replaceChildren(
      el('div', { className: 'skeleton-list', style: { padding: '12px' } }, el('div', { className: 'skeleton-bar' }), el('div', { className: 'skeleton-bar' })),
    );

    try {
      const { data } = await apiRequest('/audit', { signal: auditAbort.signal });
      const events = data.events || [];
      if (!events.length) {
        auditBox.replaceChildren(el('div', { className: 'empty-state' }, el('strong', null, '暂无审计记录')));
        return;
      }

      auditBox.replaceChildren(
        ...events.map((ev) => {
          const [label, pillCls] = ACTION_LABELS[ev.action] || [ev.action || '操作', 'pill-neutral'];
          const actorText = ev.actor_name || ev.actor_id || '系统';
          const targetSuffix = ev.target_id ? ` · 目标：${ev.target_id}` : '';
          return el(
            'div',
            { className: 'audit-item' },
            el('span', { className: 'audit-time' }, formatDate(ev.created_at)),
            el('span', { className: 'audit-action' }, el('span', { className: `pill ${pillCls}` }, label)),
            el('span', { className: 'audit-actor' }, `${actorText}${targetSuffix}`),
          );
        }),
      );
    } catch (err) {
      if (err?.name === 'AbortError') return;
      auditBox.replaceChildren(el('div', { className: 'inline-alert inline-alert-danger' }, err?.message || '加载审计日志失败'));
    }
  }

  async function activate() {
    mount();
    await Promise.all([loadMembers(), loadAudit()]);
  }

  function reset() {
    membersAbort?.abort();
    auditAbort?.abort();
    mounted = false;
    unitsLoaded = false;
    selectedUnitId = '';
    unitSelect = null;
    membersBox = null;
    auditBox = null;
    $('platform')?.replaceChildren();
  }

  return {
    activate,
    reset,
  };
}
