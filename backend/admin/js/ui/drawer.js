import { $, el } from '../core/dom.js';

let currentDrawer = null;

function getRoot() {
  return $('overlay-root') || document.body;
}

export function openDrawer({
  title = '',
  subtitle = '',
  body = null,
  footer = null,
  onClose = null,
}) {
  closeDrawer();

  const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const titleId = `drawer-title-${Date.now()}`;

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    if (currentDrawer?.close === close) currentDrawer = null;
    overlay.remove();
    onClose?.();
    if (previousFocus && document.contains(previousFocus)) {
      previousFocus.focus();
    }
  };

  const titleBlock = el(
    'div',
    null,
    el('h3', { id: titleId, className: 'modal-title' }, title),
    subtitle ? el('p', { className: 'muted', style: { fontSize: '12px', marginTop: '2px' } }, subtitle) : null,
  );

  const closeBtn = el('button', {
    type: 'button',
    className: 'drawer-close',
    'aria-label': '关闭详情抽屉',
    onClick: close,
  }, '×');

  const panel = el(
    'aside',
    {
      className: 'drawer-panel',
      role: 'dialog',
      'aria-modal': 'true',
      'aria-labelledby': titleId,
      tabindex: -1,
    },
    el('div', { className: 'drawer-header' }, titleBlock, closeBtn),
    el('div', { className: 'drawer-body' }, body),
    footer ? el('div', { className: 'drawer-footer' }, footer) : null,
  );

  const overlay = el('div', {
    className: 'drawer-overlay',
    onClick: (e) => {
      if (e.target === overlay) close();
    },
  }, panel);

  currentDrawer = { overlay, panel, close };
  getRoot().appendChild(overlay);
  panel.focus();

  return currentDrawer;
}

export function closeDrawer() {
  if (currentDrawer) {
    currentDrawer.close();
  }
}

if (typeof document !== 'undefined') {
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && currentDrawer) {
      // Let top modal handle Escape first if a modal is open above the drawer
      if (document.querySelector('.modal-overlay')) return;
      event.preventDefault();
      closeDrawer();
    }
  });
}
