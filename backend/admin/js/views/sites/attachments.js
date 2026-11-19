import { createAsyncButton, el, encodePath } from '../../core/dom.js';
import { apiDownload, apiRequest, apiUpload, mapErrorMessage } from '../../core/api.js';
import { createDropzone } from '../../ui/dropzone.js';
import { toast } from '../../ui/toast.js';

const STATUS_BADGE = {
  ready: ['已就绪', 'pill-safe'],
  queued: ['排队处理中…', 'pill-caution'],
  processing: ['正在后台处理…', 'pill-caution'],
  failed: ['处理失败', 'pill-danger'],
};

async function checkPanoramaAspectRatio(file) {
  if (!file || !file.type?.startsWith('image/')) return { ok: true };
  if (typeof createImageBitmap !== 'function') return { ok: true };
  try {
    const bmp = await createImageBitmap(file);
    const ratio = bmp.width / Math.max(1, bmp.height);
    const dims = `${bmp.width}×${bmp.height}`;
    bmp.close();
    if (Math.abs(ratio - 2) > 0.08) {
      return { ok: false, reason: `${file.name}（${dims}）宽高比非 2:1 等距柱状投影全景图` };
    }
    return { ok: true };
  } catch {
    return { ok: true };
  }
}

export function createAttachmentsPanel({
  siteId,
  module,
  limits,
  getAttachments,
  getTasks,
  onAssetsUpdated,
}) {
  const isMaps = module === 'maps';
  const assetsGrid = el('div', { className: 'asset-grid' });
  const emptyHint = el('p', { className: 'muted', style: { fontSize: '13px' }, hidden: true });
  const uploadErrorBox = el('div', { className: 'inline-alert inline-alert-danger', role: 'alert', hidden: true });

  let pollTimer = null;
  let pollBackoffMs = 2500;
  let destroyed = false;

  function stopPolling() {
    if (pollTimer) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
  }

  function buildTaskIndex() {
    const map = new Map();
    for (const t of getTasks() || []) {
      const prev = map.get(t.attachment_id);
      if (!prev || Number(t.updated_at || 0) >= Number(prev.updated_at || 0)) {
        map.set(t.attachment_id, t);
      }
    }
    return map;
  }

  function renderAssetCards() {
    const all = (getAttachments() || []).filter((f) => f.module === module);
    const taskByAtt = buildTaskIndex();

    if (!all.length) {
      emptyHint.textContent = isMaps
        ? '尚未上传平面图或 360° 全景图。上传并处理就绪后，可在下方分项中关联使用。'
        : '尚未上传应急预案文档（支持 PDF / Word / 图片）。';
      emptyHint.hidden = false;
      assetsGrid.replaceChildren();
      stopPolling();
      return;
    }

    emptyHint.hidden = true;
    const hasPending = all.some((f) => f.status === 'queued' || f.status === 'processing');

    assetsGrid.replaceChildren(
      ...all.map((file) => {
        const isPano = Boolean(file.metadata?.panorama);
        const [statusLabel, statusCls] = STATUS_BADGE[file.status] || [file.status || '未知', 'pill-neutral'];
        const task = taskByAtt.get(file.id);
        const metaParts = [
          isPano ? '360° 全景图' : (isMaps ? '平面地图/图纸' : '文档附件'),
          file.metadata?.pages ? `共 ${file.metadata.pages} 页` : null,
          file.size_bytes ? `${(file.size_bytes / 1024 / 1024).toFixed(2)} MB` : null,
        ].filter(Boolean);

        const actions = [];
        if (file.status === 'ready') {
          if (isPano) {
            actions.push(
              el('button', {
                type: 'button',
                className: 'btn btn-primary btn-xs',
                onClick: () => {
                  window.open(`/admin/pano.html?siteId=${encodePath(siteId)}&attachmentId=${encodePath(file.id)}`, '_blank', 'noopener');
                },
              }, '全屏预览 360°'),
            );
          } else {
            actions.push(
              createAsyncButton('下载原件', 'btn btn-secondary btn-xs', async () => {
                try {
                  await apiDownload(`/key-sites/${encodePath(siteId)}/attachments/${encodePath(file.id)}/source`, file.filename || 'attachment');
                } catch (err) {
                  toast.error(err?.message || '下载附件失败');
                }
              }),
            );
            if (file.metadata?.pages) {
              actions.push(
                el('a', {
                  className: 'btn btn-subtle btn-xs',
                  href: `/api/admin/key-sites/${encodePath(siteId)}/attachments/${encodePath(file.id)}/document.pdf`,
                  target: '_blank',
                  rel: 'noopener',
                }, '查看 PDF'),
              );
            }
          }
        } else if (file.status === 'failed' && task?.id) {
          actions.push(
            createAsyncButton('重试处理', 'btn btn-secondary btn-xs', async () => {
              try {
                await apiRequest(`/key-sites/tasks/${encodePath(task.id)}/retry`, { method: 'POST', body: {} });
                toast.info(`已重新提交「${file.filename}」后台处理`);
                pollBackoffMs = 2500;
                await pollNow(false);
              } catch (err) {
                toast.error(err?.message || '重试提交失败');
              }
            }),
          );
        }

        const errorReason = file.status === 'failed'
          ? mapErrorMessage(task?.error_code, task?.error_code ? `处理失败（${task.error_code}）` : '处理失败，请检查文件格式后重试')
          : '';

        return el(
          'div',
          { className: 'asset-card' },
          el(
            'div',
            { className: 'asset-card-head' },
            el('span', { className: 'asset-filename' }, file.filename || '未命名文件'),
            el('span', { className: `pill ${statusCls}` }, statusLabel),
          ),
          el('div', { className: 'asset-meta' }, metaParts.join(' · ')),
          errorReason ? el('div', { className: 'asset-error' }, errorReason) : null,
          actions.length ? el('div', { className: 'asset-actions' }, ...actions) : null,
        );
      }),
    );

    if (hasPending && !destroyed) {
      schedulePoll();
    } else {
      stopPolling();
    }
  }

  function schedulePoll() {
    stopPolling();
    pollTimer = setTimeout(() => {
      pollNow(true);
    }, pollBackoffMs);
  }

  async function pollNow(isBackgroundPoll) {
    if (destroyed) return;
    if (isBackgroundPoll && document.hidden) {
      schedulePoll();
      return;
    }
    try {
      const { data } = await apiRequest(`/key-sites/${encodePath(siteId)}`, { poll: isBackgroundPoll });
      if (destroyed) return;
      pollBackoffMs = 2500;
      onAssetsUpdated?.(data.attachments || [], data.tasks || []);
      renderAssetCards();
    } catch (err) {
      if (destroyed || err?.status === 401) return;
      // Bounded exponential backoff instead of silently halting forever
      pollBackoffMs = Math.min(20000, Math.round(pollBackoffMs * 1.8));
      schedulePoll();
    }
  }

  async function uploadBatch(files, { panorama = false, button = null, dropzone = null } = {}) {
    if (!files.length) return;
    uploadErrorBox.hidden = true;

    const maxPending = Number(limits?.unitPending) || 10;
    if (files.length > maxPending) {
      uploadErrorBox.textContent = `单批最多同时上传 ${maxPending} 个文件，请分批上传。`;
      uploadErrorBox.hidden = false;
      return;
    }

    if (button) {
      button.disabled = true;
      button.setAttribute('aria-busy', 'true');
    }

    let succeeded = 0;
    const failures = [];

    try {
      for (let i = 0; i < files.length; i += 1) {
        const file = files[i];
        if (panorama) {
          const check = await checkPanoramaAspectRatio(file);
          if (!check.ok) {
            failures.push(check.reason);
            continue;
          }
        }
        const formData = new FormData();
        formData.append('file', file);
        const qs = panorama ? '?panorama=1' : '';
        try {
          toast.info(`正在上传 (${i + 1}/${files.length})：${file.name}`, 2000);
          await apiUpload(`/key-sites/${encodePath(siteId)}/attachments/${encodePath(module)}${qs}`, formData);
          succeeded += 1;
        } catch (err) {
          failures.push(`${file.name}：${err?.message || '上传失败'}`);
          if (err?.status === 401) break;
        }
      }
    } finally {
      dropzone?.reset();
      if (button) {
        button.disabled = false;
        button.removeAttribute('aria-busy');
      }
      if (succeeded > 0) {
        toast.success(`已上传 ${succeeded} 个文件，正在后台处理`);
        pollBackoffMs = 2500;
        await pollNow(false);
      }
      if (failures.length > 0) {
        uploadErrorBox.textContent = `部分文件未上传：${failures.join('；')}`;
        uploadErrorBox.hidden = false;
      }
    }
  }

  const uploadControls = [];
  if (isMaps) {
    let pendingPanoFiles = [];
    const panoUploadBtn = el('button', { type: 'button', className: 'btn btn-primary btn-sm', disabled: true }, '上传 360° 全景图');
    const panoZone = createDropzone({
      accept: 'image/jpeg,image/png,image/webp',
      multiple: true,
      title: '上传 360° 全景图（支持多选与拖拽）',
      subtitle: '要求 2:1 等距柱状投影全景图（JPG/PNG/WebP），自动压缩生成 3D 球面纹理',
      onSelect: (files) => {
        pendingPanoFiles = files;
        panoUploadBtn.disabled = !files.length;
      },
    });
    panoUploadBtn.addEventListener('click', () => {
      const files = [...pendingPanoFiles];
      pendingPanoFiles = [];
      uploadBatch(files, { panorama: true, button: panoUploadBtn, dropzone: panoZone });
    });

    let pendingMapFiles = [];
    const mapUploadBtn = el('button', { type: 'button', className: 'btn btn-secondary btn-sm', disabled: true }, '上传平面图 / PDF');
    const mapZone = createDropzone({
      accept: '.pdf,.doc,.docx,.jpg,.jpeg,.png,.webp',
      multiple: false,
      title: '上传平面总图 / 楼层图（PDF / Word / 图片）',
      subtitle: '上传后自动分页并生成高清晰度地图切片，供下方分项按页关联',
      onSelect: (files) => {
        pendingMapFiles = files;
        mapUploadBtn.disabled = !files.length;
      },
    });
    mapUploadBtn.addEventListener('click', () => {
      const files = [...pendingMapFiles];
      pendingMapFiles = [];
      uploadBatch(files, { panorama: false, button: mapUploadBtn, dropzone: mapZone });
    });

    uploadControls.push(
      el(
        'div',
        { className: 'form-grid-2' },
        el('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } }, panoZone.element, panoUploadBtn),
        el('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } }, mapZone.element, mapUploadBtn),
      ),
    );
  } else {
    let pendingDocFiles = [];
    const docUploadBtn = el('button', { type: 'button', className: 'btn btn-secondary btn-sm', disabled: true }, '上传预案文档');
    const docZone = createDropzone({
      accept: '.pdf,.doc,.docx,.jpg,.jpeg,.png',
      multiple: false,
      title: '上传应急预案原件（PDF / Word / 扫描图）',
      subtitle: '后台自动转换并存档，便于指挥端随时查阅',
      onSelect: (files) => {
        pendingDocFiles = files;
        docUploadBtn.disabled = !files.length;
      },
    });
    docUploadBtn.addEventListener('click', () => {
      const files = [...pendingDocFiles];
      pendingDocFiles = [];
      uploadBatch(files, { panorama: false, button: docUploadBtn, dropzone: docZone });
    });
    uploadControls.push(
      el('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } }, docZone.element, docUploadBtn),
    );
  }

  const readyPanoCount = () => (getAttachments() || []).filter((f) => f.module === 'maps' && f.status === 'ready' && f.metadata?.panorama).length;
  const openAllPanoBtn = isMaps
    ? el('button', {
      type: 'button',
      className: 'btn btn-secondary btn-sm',
      onClick: () => {
        if (!readyPanoCount()) {
          toast.warn('当前尚无已就绪的 360° 全景图');
          return;
        }
        window.open(`/admin/pano.html?siteId=${encodePath(siteId)}`, '_blank', 'noopener');
      },
    }, '打开 360° 全景总览')
    : null;

  const element = el(
    'section',
    { className: 'editor-section-card' },
    el(
      'div',
      { className: 'editor-section-head' },
      el(
        'div',
        null,
        el('h3', null, isMaps ? '地图与 360° 全景素材库' : '应急预案附件文档'),
        el('p', { className: 'editor-section-help' }, '素材上传后后台自动排队处理，状态将局部刷新，不会清空当前正在填写的表单。'),
      ),
      openAllPanoBtn,
    ),
    ...uploadControls,
    uploadErrorBox,
    emptyHint,
    assetsGrid,
  );

  renderAssetCards();

  return {
    element,
    refresh: renderAssetCards,
    destroy() {
      destroyed = true;
      stopPolling();
    },
  };
}
