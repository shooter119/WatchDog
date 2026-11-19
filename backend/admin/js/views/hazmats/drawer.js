import { createAsyncButton, el } from '../../core/dom.js';
import { openDrawer } from '../../ui/drawer.js';

export const EMPTY_TACTICAL_PLACEHOLDER = '未录入（请核对 SDS / ERG）';

export function formatTacticalField(value) {
  const text = String(value ?? '').trim();
  return text ? { text, empty: false } : { text: EMPTY_TACTICAL_PLACEHOLDER, empty: true };
}

export function waterReactivityMeta(level) {
  if (level === 'forbidden') return { label: '严禁用水', pillClass: 'pill-danger' };
  if (level === 'reactive') return { label: '遇水剧烈反应', pillClass: 'pill-caution' };
  return { label: '常规水反应性', pillClass: 'pill-safe' };
}

export function signColorClass(color) {
  const valid = ['red', 'blue', 'yellow', 'white', 'black_white'];
  return valid.includes(color) ? `pill-sign-${color}` : 'pill-sign-default';
}

function kvItem(label, value, spanFull = false) {
  const formatted = formatTacticalField(value);
  return el(
    'div',
    { className: `tactical-kv${spanFull ? ' form-span-full' : ''}` },
    el('span', { className: 'tactical-kv-label' }, label),
    el('span', { className: `tactical-kv-value${formatted.empty ? ' tactical-empty' : ''}` }, formatted.text),
  );
}

export function openHazmatDrawer(item, { onEdit, onDelete }) {
  const water = waterReactivityMeta(item.water_reactivity);
  const subtitleParts = [
    item.name_en,
    item.un_number ? `UN ${item.un_number}` : '',
    item.cas_number ? `CAS ${item.cas_number}` : '',
  ].filter(Boolean);

  const sections = [];

  if (item.water_reactivity === 'forbidden' || item.water_reactivity === 'reactive') {
    const forbiddenText = formatTacticalField(item.forbidden_agents);
    sections.push(
      el(
        'div',
        { className: 'tactical-banner' },
        el('strong', null, item.water_reactivity === 'forbidden' ? '⚠ 红线禁忌：严禁直接用水扑救' : '⚠ 注意：该物质遇水剧烈反应'),
        el('span', null, forbiddenText.empty ? '请在现场处置前严格核对禁忌灭火剂清单。' : `禁忌灭火剂：${forbiddenText.text}`),
      ),
    );
  }

  sections.push(
    el(
      'div',
      { style: { display: 'flex', gap: '8px', flexWrap: 'wrap' } },
      item.danger_category
        ? el('span', { className: `pill ${signColorClass(item.danger_sign_color)}` }, item.danger_category)
        : el('span', { className: 'pill pill-neutral' }, '未分类别'),
      el('span', { className: `pill ${water.pillClass}` }, water.label),
    ),
  );

  if (Array.isArray(item.aliases) && item.aliases.length > 0) {
    sections.push(
      el(
        'div',
        { className: 'tactical-section' },
        el('div', { className: 'tactical-section-title' }, '别名 / 俗名 / 商品名'),
        el('div', { className: 'alias-badges' }, ...item.aliases.map((a) => el('span', { className: 'alias-tag' }, a))),
      ),
    );
  }

  sections.push(
    el(
      'div',
      { className: 'tactical-section' },
      el('div', { className: 'tactical-section-title' }, '核心危险与灭火战术'),
      el(
        'div',
        { className: 'tactical-kv-grid' },
        kvItem('核心风险概述', item.danger_summary, true),
        kvItem('禁用灭火剂', item.forbidden_agents, true),
        kvItem('推荐灭火剂', item.extinguishing_agents, true),
        kvItem('扑救战术要点', item.firefighting_tips, true),
      ),
    ),
    el(
      'div',
      { className: 'tactical-section' },
      el('div', { className: 'tactical-section-title' }, '防护、警戒与应急洗消'),
      el(
        'div',
        { className: 'tactical-kv-grid' },
        kvItem('个体防护等级', item.protective_level),
        kvItem('初始隔离/疏散距离', item.isolation_distance),
        kvItem('泄漏堵漏处置', item.leak_handling, true),
        kvItem('现场急救与洗消', item.first_aid, true),
      ),
    ),
    el(
      'div',
      { className: 'tactical-section' },
      el('div', { className: 'tactical-section-title' }, '理化特性与备注'),
      el(
        'div',
        { className: 'tactical-kv-grid' },
        kvItem('外观与气味', item.appearance, true),
        kvItem('闪点 / 自燃点', item.flash_point),
        kvItem('爆炸极限', item.explosion_limit),
        kvItem('相对蒸气密度', item.vapor_density),
        kvItem('补充备注', item.notes, true),
      ),
    ),
  );

  const drawer = openDrawer({
    title: item.name_cn || '危化品处置详情',
    subtitle: subtitleParts.join(' · '),
    body: sections,
    footer: [
      createAsyncButton('删除记录', 'btn btn-danger-outline btn-sm', async () => {
        const deleted = await onDelete?.(item);
        if (deleted) drawer.close();
      }),
      el('button', {
        type: 'button',
        className: 'btn btn-primary btn-sm',
        onClick: () => {
          drawer.close();
          onEdit?.(item);
        },
      }, '编辑危化品'),
    ],
  });

  return drawer;
}
