export const $ = (id) => document.getElementById(id);

export function el(tag, attrs = null, ...children) {
  const node = document.createElement(tag);
  if (attrs && typeof attrs === 'object') {
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === 'className' || key === 'class') {
        node.className = String(value);
      } else if (key === 'dataset' && typeof value === 'object') {
        for (const [dk, dv] of Object.entries(value)) {
          if (dv !== undefined && dv !== null) node.dataset[dk] = String(dv);
        }
      } else if (key === 'style' && typeof value === 'object') {
        Object.assign(node.style, value);
      } else if (key.startsWith('on') && typeof value === 'function') {
        node.addEventListener(key.slice(2).toLowerCase(), value);
      } else if (key in node && key !== 'list' && key !== 'role' && !key.startsWith('aria-') && !key.startsWith('data-')) {
        node[key] = value;
      } else {
        node.setAttribute(key, value === true ? '' : String(value));
      }
    }
  }
  appendChildren(node, children);
  return node;
}

function appendChildren(parent, items) {
  for (const item of items) {
    if (item === undefined || item === null || item === false) continue;
    if (Array.isArray(item)) {
      appendChildren(parent, item);
    } else if (item instanceof Node) {
      parent.appendChild(item);
    } else {
      parent.appendChild(document.createTextNode(String(item)));
    }
  }
}

export function formatDate(value) {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) return '—';
  const d = new Date(num);
  if (Number.isNaN(d.getTime())) return '—';
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function debounce(fn, delay = 250) {
  let timer = null;
  const wrapped = (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn(...args);
    }, delay);
  };
  wrapped.cancel = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };
  return wrapped;
}

export function encodePath(value) {
  return encodeURIComponent(String(value ?? ''));
}

export function createAsyncButton(label, className, onClick, attrs = {}) {
  let busy = false;
  const btn = el('button', { type: 'button', className, ...attrs }, label);
  btn.addEventListener('click', async (event) => {
    if (busy || btn.disabled) return;
    busy = true;
    btn.disabled = true;
    btn.setAttribute('aria-busy', 'true');
    try {
      await onClick(event, btn);
    } finally {
      busy = false;
      btn.disabled = false;
      btn.removeAttribute('aria-busy');
    }
  });
  return btn;
}
