import { el } from '../core/dom.js';

export function createTagInput({
  initialTags = [],
  placeholder = '输入别名后按回车或逗号添加',
  onChange = null,
} = {}) {
  const tags = Array.from(new Set((initialTags || []).map((t) => String(t || '').trim()).filter(Boolean)));

  const chipsWrap = el('span', { style: { display: 'contents' } });
  const input = el('input', {
    type: 'text',
    className: 'tag-input-field',
    placeholder,
  });

  function renderChips() {
    chipsWrap.replaceChildren();
    tags.forEach((tag, idx) => {
      const chip = el(
        'span',
        { className: 'tag-chip' },
        tag,
        el('button', {
          type: 'button',
          className: 'tag-chip-remove',
          'aria-label': `移除 ${tag}`,
          onClick: (e) => {
            e.stopPropagation();
            tags.splice(idx, 1);
            renderChips();
            onChange?.([...tags]);
            input.focus();
          },
        }, '×'),
      );
      chipsWrap.appendChild(chip);
    });
  }

  function commitRaw(raw) {
    const parts = String(raw || '')
      .split(/[;,，；、\n\r]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    let added = false;
    for (const part of parts) {
      if (!tags.includes(part)) {
        tags.push(part);
        added = true;
      }
    }
    if (added) {
      renderChips();
      onChange?.([...tags]);
    }
    input.value = '';
  }

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ',' || e.key === '，' || e.key === ';' || e.key === '；') {
      e.preventDefault();
      commitRaw(input.value);
    } else if (e.key === 'Backspace' && !input.value && tags.length > 0) {
      tags.pop();
      renderChips();
      onChange?.([...tags]);
    }
  });

  input.addEventListener('blur', () => {
    if (input.value.trim()) {
      commitRaw(input.value);
    }
  });

  const container = el(
    'div',
    {
      className: 'tag-input-box',
      onClick: () => input.focus(),
    },
    chipsWrap,
    input,
  );

  renderChips();

  return {
    element: container,
    getTags() {
      if (input.value.trim()) commitRaw(input.value);
      return [...tags];
    },
    focus: () => input.focus(),
  };
}
