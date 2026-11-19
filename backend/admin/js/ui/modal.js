import { $, el } from '../core/dom.js';

const activeModals = [];

function getRoot() {
  return $('overlay-root') || document.body;
}

export function openModal({
  title = '',
  size = 'md',
  body = null,
  footer = null,
  form = null,
  closeOnBackdrop = true,
  onClose = null,
}) {
  const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const titleId = `modal-title-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    const idx = activeModals.indexOf(api);
    if (idx !== -1) activeModals.splice(idx, 1);
    overlay.remove();
    onClose?.();
    if (previousFocus && document.contains(previousFocus)) {
      previousFocus.focus();
    }
  };

  const closeBtn = el('button', {
    type: 'button',
    className: 'modal-close',
    'aria-label': '关闭弹窗',
    onClick: close,
  }, '×');

  const header = el(
    'div',
    { className: 'modal-header' },
    el('h3', { id: titleId, className: 'modal-title' }, title),
    closeBtn,
  );

  const windowClass = `modal-window${size === 'sm' ? ' modal-sm' : size === 'lg' ? ' modal-lg' : ''}`;
  const winChildren = [header];
  if (form) {
    form.classList.add('modal-form');
    winChildren.push(form);
  } else {
    if (body) winChildren.push(el('div', { className: 'modal-body' }, body));
    if (footer) winChildren.push(el('div', { className: 'modal-footer' }, footer));
  }

  const win = el('div', {
    className: windowClass,
    role: 'dialog',
    'aria-modal': 'true',
    'aria-labelledby': titleId,
    tabindex: -1,
  }, ...winChildren);

  const overlay = el('div', {
    className: 'modal-overlay',
    onClick: (e) => {
      if (closeOnBackdrop && e.target === overlay) close();
    },
  }, win);

  const api = { overlay, win, close };
  activeModals.push(api);
  getRoot().appendChild(overlay);

  const firstInput = win.querySelector('input:not([type="hidden"]), select, textarea, button:not(.modal-close)');
  (firstInput || win).focus();

  return api;
}

export function closeAllModals() {
  while (activeModals.length) {
    activeModals[activeModals.length - 1].close();
  }
}

export function confirmDialog({
  title = '请确认操作',
  message = '',
  confirmText = '确认',
  cancelText = '取消',
  danger = false,
}) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      modal.close();
      resolve(value);
    };

    const modal = openModal({
      title,
      size: 'sm',
      body: el('p', { className: 'muted' }, message),
      footer: [
        el('button', {
          type: 'button',
          className: 'btn btn-secondary',
          onClick: () => finish(false),
        }, cancelText),
        el('button', {
          type: 'button',
          className: `btn ${danger ? 'btn-danger' : 'btn-primary'}`,
          onClick: () => finish(true),
        }, confirmText),
      ],
      onClose: () => {
        if (!settled) {
          settled = true;
          resolve(false);
        }
      },
    });
  });
}

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && activeModals.length > 0) {
    event.preventDefault();
    activeModals[activeModals.length - 1].close();
  }
});
