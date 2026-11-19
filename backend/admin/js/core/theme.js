const THEME_KEY = 'watchdog_admin_theme';

export function initTheme(toggleBtn, iconEl, labelEl) {
  let current = 'daylight';
  try {
    const saved = localStorage.getItem(THEME_KEY);
    if (saved === 'night-tactical' || saved === 'daylight') current = saved;
  } catch {
    // ignore
  }

  function apply(theme) {
    current = theme;
    document.documentElement.setAttribute('data-theme', theme);
    if (iconEl) iconEl.textContent = theme === 'night-tactical' ? '☾' : '☀';
    if (labelEl) labelEl.textContent = theme === 'night-tactical' ? '暗夜指挥室' : '白昼指挥';
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch {
      // ignore
    }
  }

  apply(current);

  toggleBtn?.addEventListener('click', () => {
    apply(current === 'daylight' ? 'night-tactical' : 'daylight');
  });

  return {
    getTheme: () => current,
    setTheme: apply,
  };
}
