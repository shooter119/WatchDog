import { $ } from './core/dom.js';
import { createSessionManager } from './core/session.js';
import { createRouter, parseRouteFromHash } from './core/router.js';
import { initTheme } from './core/theme.js';
import { closeAllModals, confirmDialog } from './ui/modal.js';
import { closeDrawer } from './ui/drawer.js';
import { toast } from './ui/toast.js';
import { createLoginView } from './views/login.js';
import { createSitesView } from './views/sites/index.js';
import { createHazmatsView } from './views/hazmats/index.js';
import { createAccessView } from './views/access/index.js';

const ROUTE_META = {
  sites: { title: '重点单位资料', navId: 'show-sites', panelId: 'site-manager' },
  panos: { title: '360° 全景漫游', navId: 'show-panos', panelId: 'site-manager' },
  hazmats: { title: '危化品速查库', navId: 'show-hazmats', panelId: 'hazmat-manager' },
  access: { title: '后台授权与审计', navId: 'show-permissions', panelId: 'platform' },
};

const ADMIN_ROLE_TEXT = {
  platform_admin: '平台管理员',
  unit_admin: '单位资料管理员',
};

function updateIdentityUI(member) {
  const welcomeEl = $('welcome');
  const identityEl = $('identity');
  const avatarEl = $('user-avatar');
  const permBtn = $('show-permissions');

  const name = member?.real_name || member?.name || '管理员';
  const roleLabel = ADMIN_ROLE_TEXT[member?.admin_role] || '后台管理员';
  const unitLabel = member?.unit_name ? `${member.unit_name} · ` : '';

  if (welcomeEl) welcomeEl.textContent = name;
  if (identityEl) identityEl.textContent = `${unitLabel}${roleLabel}`;
  if (avatarEl) avatarEl.textContent = name.trim().slice(0, 1) || '管';
  if (permBtn) permBtn.hidden = member?.admin_role !== 'platform_admin';
}

function updateConnectivityUI(offline) {
  const banner = $('network-banner');
  const dot = $('conn-dot');
  const text = $('conn-text');
  if (banner) banner.hidden = !offline;
  if (dot) dot.classList.toggle('offline', offline);
  if (text) text.textContent = offline ? '连接中断' : '会话正常';
}

function updateActiveNavAndPanels(route) {
  const meta = ROUTE_META[route] || ROUTE_META.sites;
  const pageTitle = $('page-title');
  if (pageTitle) pageTitle.textContent = meta.title;

  for (const [key, cfg] of Object.entries(ROUTE_META)) {
    const navBtn = $(cfg.navId);
    if (navBtn) {
      const isActive = key === route;
      navBtn.classList.toggle('active', isActive);
      navBtn.setAttribute('aria-current', isActive ? 'page' : 'false');
    }
  }

  const panels = ['site-manager', 'hazmat-manager', 'platform'];
  for (const id of panels) {
    const panel = $(id);
    if (panel) panel.hidden = id !== meta.panelId;
  }
}

async function bootstrap() {
  initTheme($('toggle-theme'), $('theme-icon'), $('theme-label'));

  const session = createSessionManager();
  const dirtyIndicator = $('dirty-indicator');
  const workspaceEl = $('workspace');

  const sitesView = createSitesView({
    getMember: session.getMember,
    onDirtyChange: (isDirty) => {
      if (dirtyIndicator) dirtyIndicator.hidden = !isDirty;
    },
  });
  const hazmatsView = createHazmatsView();
  const accessView = createAccessView();

  const router = createRouter({
    getMember: session.getMember,
    onBeforeLeave: async (fromRoute) => {
      if (fromRoute === 'sites' || fromRoute === 'panos') {
        return sitesView.canLeave();
      }
      return true;
    },
    onRouteChange: async (route) => {
      closeDrawer();
      closeAllModals();
      updateActiveNavAndPanels(route);
      if (route === 'sites') {
        await sitesView.activateSites();
      } else if (route === 'panos') {
        await sitesView.activatePanos();
      } else if (route === 'hazmats') {
        await hazmatsView.activate();
      } else if (route === 'access') {
        await accessView.activate();
      }
    },
  });

  const loginView = createLoginView({
    session,
    onLoginSuccess: (member, csrf) => {
      session.activate(member, csrf);
      toast.success(`欢迎回来，${member?.real_name || '管理员'}`);
    },
  });

  // Session lifecycle wiring
  session.on('started', (member) => {
    // CRITICAL: explicitly hide login view & destroy QR DOM/timers before entering workspace
    loginView.hide();
    updateIdentityUI(member);
    updateConnectivityUI(false);
    if (workspaceEl) workspaceEl.hidden = false;
    const initialRoute = parseRouteFromHash();
    router.navigate(initialRoute, { syncHash: true, force: true });
  });

  session.on('refreshed', (member) => {
    // Only refresh identity metadata — never remount active views or wipe unsaved forms
    updateIdentityUI(member);
  });

  session.on('connectivity', ({ offline }) => {
    updateConnectivityUI(offline);
  });

  session.on('ended', ({ reason, hadSession }) => {
    closeDrawer();
    closeAllModals();
    sitesView.reset();
    hazmatsView.reset();
    accessView.reset();
    router.resetToDefault();
    if (dirtyIndicator) dirtyIndicator.hidden = true;
    updateConnectivityUI(false);
    if (workspaceEl) workspaceEl.hidden = true;
    loginView.show(hadSession ? reason : '');
  });

  // Sidebar navigation bindings
  for (const [route, cfg] of Object.entries(ROUTE_META)) {
    $(cfg.navId)?.addEventListener('click', () => {
      router.navigate(route);
    });
  }

  // Network retry button
  $('network-retry')?.addEventListener('click', () => {
    session.retryHeartbeat();
  });

  // Logout controls
  const logoutBtn = $('logout');
  logoutBtn?.addEventListener('click', async () => {
    if (!(await sitesView.canLeave())) return;
    logoutBtn.disabled = true;
    try {
      await session.logout(false);
    } finally {
      logoutBtn.disabled = false;
    }
  });

  const logoutAllBtn = $('logout-all');
  logoutAllBtn?.addEventListener('click', async () => {
    if (!(await sitesView.canLeave())) return;
    const ok = await confirmDialog({
      title: '退出全部设备会话',
      message: '此操作将使您当前所有浏览器和设备上的管理后台登录态立即失效，需要重新扫码登录。确认继续吗？',
      confirmText: '确认全部下线',
      danger: true,
    });
    if (!ok) return;
    logoutAllBtn.disabled = true;
    try {
      await session.logout(true);
    } finally {
      logoutAllBtn.disabled = false;
    }
  });

  // Guard against accidental tab close / refresh with unsaved key-site edits
  window.addEventListener('beforeunload', (event) => {
    if (sitesView.isDirty()) {
      event.preventDefault();
      event.returnValue = '';
    }
  });

  // Initial session check
  const restored = await session.restore();
  if (!restored) {
    if (workspaceEl) workspaceEl.hidden = true;
    loginView.show('');
  }
}

bootstrap();
