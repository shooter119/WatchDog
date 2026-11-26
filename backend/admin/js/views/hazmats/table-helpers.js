const INTERACTIVE_ROW_SELECTOR = 'button, a, input, select, textarea, label, [role="button"]';

export function shouldOpenDrawerFromRowClick(event, getSelectionText) {
  const target = event?.target;
  if (target && typeof target.closest === 'function' && target.closest(INTERACTIVE_ROW_SELECTOR)) {
    return false;
  }
  const selected = typeof getSelectionText === 'function'
    ? String(getSelectionText() || '').trim()
    : String(globalThis.window?.getSelection?.()?.toString?.() || '').trim();
  if (selected.length > 0) {
    return false;
  }
  return true;
}

export function computeRiskPopoverPosition(anchorRect, popoverSize, viewport, margin = 12, gap = 8) {
  const vw = Math.max(0, Number(viewport?.width || 0));
  const vh = Math.max(0, Number(viewport?.height || 0));
  const pw = Math.max(0, Number(popoverSize?.width || 0));
  const ph = Math.max(0, Number(popoverSize?.height || 0));

  let left = Number(anchorRect?.left || 0);
  if (left + pw + margin > vw) {
    left = vw - pw - margin;
  }
  left = Math.max(margin, left);

  let top = Number(anchorRect?.bottom || 0) + gap;
  if (top + ph + margin > vh) {
    const above = Number(anchorRect?.top || 0) - ph - gap;
    top = above >= margin ? above : Math.max(margin, vh - ph - margin);
  }
  return { left: Math.round(left), top: Math.round(top) };
}
