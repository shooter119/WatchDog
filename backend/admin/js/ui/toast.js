import { $, el } from '../core/dom.js';

const MAX_TOASTS = 4;

export function showToast(message, type = 'info', durationMs = 3600) {
  const stack = $('toast-stack');
  if (!stack || !message) return;

  while (stack.children.length >= MAX_TOASTS) {
    stack.firstElementChild?.remove();
  }

  let timer = null;
  const dismiss = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    item.remove();
  };

  const item = el(
    'div',
    {
      className: `toast-item toast-${type}`,
      role: type === 'error' ? 'alert' : 'status',
    },
    el('span', null, String(message)),
    el('button', {
      type: 'button',
      className: 'toast-dismiss',
      'aria-label': '关闭提示',
      onClick: dismiss,
    }, '×'),
  );

  stack.appendChild(item);
  if (durationMs > 0) {
    timer = setTimeout(dismiss, durationMs);
  }
}

export const toast = {
  info: (msg, ms = 3200) => showToast(msg, 'info', ms),
  success: (msg, ms = 3200) => showToast(msg, 'success', ms),
  warn: (msg, ms = 4200) => showToast(msg, 'warn', ms),
  error: (msg, ms = 5000) => showToast(msg, 'error', ms),
};
