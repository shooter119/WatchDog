import { createAsyncButton, el } from '../../core/dom.js';
import { apiDownload, apiUpload } from '../../core/api.js';
import { openModal } from '../../ui/modal.js';
import { createDropzone } from '../../ui/dropzone.js';
import { toast } from '../../ui/toast.js';

export function openHazmatImportModal({ onImported }) {
  let selectedFile = null;

  const overwriteCheck = el('input', { type: 'checkbox', checked: true });
  const resultBox = el('div', { hidden: true });
  const errorBox = el('div', { className: 'inline-alert inline-alert-danger', role: 'alert', hidden: true });

  const startBtn = el('button', { type: 'button', className: 'btn btn-primary', disabled: true }, '开始导入');
  const closeBtn = el('button', { type: 'button', className: 'btn btn-secondary' }, '关闭');

  const dropzone = createDropzone({
    accept: '.xlsx,.xls,.csv',
    multiple: false,
    title: '点击选择 Excel / CSV 文件，或拖拽表格到此区域',
    subtitle: '支持 .xlsx / .xls / .csv，单文件最大 10MB，单次最多 2000 条记录',
    onSelect: (files) => {
      selectedFile = files[0] || null;
      startBtn.disabled = !selectedFile;
      errorBox.hidden = true;
      resultBox.hidden = true;
    },
  });

  const downloadXlsxBtn = createAsyncButton('下载 Excel 模板 (.xlsx)', 'btn btn-secondary btn-sm', async () => {
    try {
      await apiDownload('/hazmats/template?format=xlsx', 'hazmat_template.xlsx');
    } catch (err) {
      toast.error(err?.message || '模板下载失败');
    }
  });

  const downloadCsvBtn = createAsyncButton('下载 CSV 模板 (.csv)', 'btn btn-subtle btn-sm', async () => {
    try {
      await apiDownload('/hazmats/template?format=csv', 'hazmat_template.csv');
    } catch (err) {
      toast.error(err?.message || '模板下载失败');
    }
  });

  const body = el(
    'div',
    { style: { display: 'flex', flexDirection: 'column', gap: '14px' } },
    el(
      'div',
      { className: 'inline-alert inline-alert-info' },
      el(
        'div',
        null,
        el('strong', null, '导入说明：'),
        '系统按中文品名或 UN 编号自动识别已有记录。勾选下方选项后将覆盖更新已有条目，未勾选则跳过重复条目。',
      ),
    ),
    el('div', { className: 'toolbar-actions' }, downloadXlsxBtn, downloadCsvBtn),
    dropzone.element,
    el(
      'label',
      { style: { display: 'inline-flex', alignItems: 'center', gap: '8px', fontSize: '13px', cursor: 'pointer' } },
      overwriteCheck,
      el('span', null, '覆盖更新库内已有危化品记录（按中文品名或 UN 编号匹配）'),
    ),
    errorBox,
    resultBox,
  );

  const modal = openModal({
    title: '批量导入危化品目录',
    size: 'md',
    body,
    footer: [closeBtn, startBtn],
  });

  closeBtn.addEventListener('click', () => modal.close());

  startBtn.addEventListener('click', async () => {
    if (!selectedFile || startBtn.disabled) return;
    startBtn.disabled = true;
    startBtn.setAttribute('aria-busy', 'true');
    startBtn.textContent = '正在解析并导入…';
    errorBox.hidden = true;
    resultBox.hidden = true;

    try {
      const formData = new FormData();
      formData.append('file', selectedFile);
      formData.append('overwrite', String(overwriteCheck.checked));
      const res = await apiUpload('/hazmats/import', formData);

      const totalRows = Number(res.totalRows ?? 0);
      const imported = Number(res.imported ?? 0);
      const updated = Number(res.updated ?? 0);
      const skipped = Number(res.skipped ?? 0);
      const errors = Array.isArray(res.errors) ? res.errors : [];

      const summaryChildren = [
        el('strong', null, '导入完成'),
        el('div', null, `总计读取 ${totalRows} 行 ｜ 新增 ${imported} 条 ｜ 更新 ${updated} 条 ｜ 跳过 ${skipped} 条 ｜ 失败 ${errors.length} 条`),
      ];

      if (errors.length > 0) {
        const errList = el(
          'ul',
          { style: { margin: '8px 0 0', paddingLeft: '18px', fontSize: '12px' } },
          ...errors.slice(0, 20).map((e) => el('li', null, `第 ${e.row ?? '?'} 行${e.name ? `（${e.name}）` : ''}：${e.message || '导入失败'}`)),
        );
        if (errors.length > 20) {
          errList.appendChild(el('li', null, `……另有 ${errors.length - 20} 条错误已省略`));
        }
        summaryChildren.push(errList);
      }

      resultBox.className = `inline-alert ${errors.length ? 'inline-alert-caution' : 'inline-alert-safe'}`;
      resultBox.replaceChildren(el('div', null, ...summaryChildren));
      resultBox.hidden = false;

      toast.success(`批量导入完成：新增 ${imported} 条，更新 ${updated} 条`);
      await onImported?.();
    } catch (err) {
      errorBox.textContent = err?.message || '批量导入失败，请检查文件格式';
      errorBox.hidden = false;
    } finally {
      startBtn.removeAttribute('aria-busy');
      startBtn.textContent = '开始导入';
      startBtn.disabled = !selectedFile;
    }
  });

  return modal;
}
