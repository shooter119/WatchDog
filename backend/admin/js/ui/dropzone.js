import { el } from '../core/dom.js';

export function createDropzone({
  accept = '',
  multiple = false,
  title = '点击选择文件，或将文件拖拽到此处',
  subtitle = '',
  onSelect = null,
} = {}) {
  let selectedFiles = [];

  const fileInput = el('input', {
    type: 'file',
    accept,
    multiple,
    hidden: true,
  });

  const selectedLabel = el('span', { className: 'file-dropzone-selected', hidden: true });

  function updateFiles(fileList) {
    const files = Array.from(fileList || []);
    if (!files.length) return;
    selectedFiles = multiple ? files : [files[0]];
    selectedLabel.hidden = false;
    selectedLabel.textContent = selectedFiles.length === 1
      ? `已选择：${selectedFiles[0].name}（${(selectedFiles[0].size / 1024).toFixed(1)} KB）`
      : `已选择 ${selectedFiles.length} 个文件`;
    onSelect?.(selectedFiles);
  }

  fileInput.addEventListener('change', () => {
    if (fileInput.files && fileInput.files.length > 0) {
      updateFiles(fileInput.files);
    }
  });

  const zone = el(
    'div',
    {
      className: 'file-dropzone',
      role: 'button',
      tabindex: 0,
      onClick: () => fileInput.click(),
      onKeydown: (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          fileInput.click();
        }
      },
    },
    fileInput,
    el('span', { className: 'file-dropzone-title' }, title),
    subtitle ? el('span', { className: 'file-dropzone-sub' }, subtitle) : null,
    selectedLabel,
  );

  zone.addEventListener('dragenter', (e) => {
    e.preventDefault();
    zone.classList.add('is-dragover');
  });
  zone.addEventListener('dragover', (e) => {
    e.preventDefault();
    zone.classList.add('is-dragover');
  });
  zone.addEventListener('dragleave', (e) => {
    if (!zone.contains(e.relatedTarget)) {
      zone.classList.remove('is-dragover');
    }
  });
  zone.addEventListener('drop', (e) => {
    e.preventDefault();
    zone.classList.remove('is-dragover');
    if (e.dataTransfer?.files?.length) {
      updateFiles(e.dataTransfer.files);
    }
  });

  return {
    element: zone,
    getFiles: () => [...selectedFiles],
    reset() {
      selectedFiles = [];
      fileInput.value = '';
      selectedLabel.textContent = '';
      selectedLabel.hidden = true;
    },
  };
}
