#!/usr/bin/env bash
#
# 异地备份：把线上数据库与私有资料卷拉回本机。
#
# 线上 /opt/watchdog/backups/ 与数据库同盘，宿主机磁盘损坏或误删会同时丢库和
# 备份；本脚本补一份离开 VPS 的副本（默认落在仓库之外的 ~/WatchDog-backups）。
#
# 拉取内容：
#   database.dump      PostgreSQL 自定义格式 dump（pg_dump -Fc）
#   private-data.tgz   后端 /app/data 私有卷（重点单位资料原件与切片）
#   ota-latest.json    当前 OTA 清单（发布链路核对用）
#   manifest.txt       生成时间、容器、大小与 sha256
#
# 用法：
#   scripts/backup-pull.sh                  # 拉取一次并保留最近 10 份
#   scripts/backup-pull.sh --keep 30        # 保留最近 30 份
#   scripts/backup-pull.sh --dest /Volumes/usb/watchdog
#   scripts/backup-pull.sh --dry-run        # 只打印将要执行的动作
#
# 环境变量：BACKUP_HOST（默认 ali）、BACKUP_ROOT（默认 /opt/watchdog）、
#           BACKUP_DEST（默认 ~/WatchDog-backups）
#
# 只读取线与写本地：不删除线上业务数据，不触碰 .env.production 等密钥文件。
set -euo pipefail

BACKUP_HOST="${BACKUP_HOST:-ali}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/watchdog}"
BACKUP_DEST="${BACKUP_DEST:-$HOME/WatchDog-backups}"
# 线上改名、迁移目录时先在这里显式改白名单，避免脚本在错误路径上"备份成功"。
[[ "$BACKUP_HOST" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo '备份主机格式无效' >&2; exit 1; }
[[ "$BACKUP_ROOT" =~ ^/[A-Za-z0-9_/-]+$ ]] || { echo '线上根目录格式无效' >&2; exit 1; }

KEEP=10
DRY_RUN=0
while (($#)); do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --dest) BACKUP_DEST="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo '--keep 必须是正整数' >&2; exit 1; }

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="offsite-${STAMP}.tar.gz"

step "检查备份目标"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$BACKUP_HOST" "true" || die "无法免密登录 ${BACKUP_HOST}（需要 ssh 公钥，不接受交互密码）"
info "线上：${BACKUP_HOST}:${BACKUP_ROOT}"
info "本地：${BACKUP_DEST}"
[[ "$DRY_RUN" -eq 1 ]] && info "（dry-run：不做任何改动）"

step "线上打包数据库与私有资料"
REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
umask 077
root="$1"; stamp="$2"; archive="$3"
backups="$root/backups"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$backups"

db="$(docker ps -q --filter label=com.docker.compose.service=database | head -1)"
backend="$(docker ps -q --filter label=com.docker.compose.service=backend | head -1)"
[[ -n "$db" ]] || { echo '未找到数据库容器' >&2; exit 1; }
[[ -n "$backend" ]] || { echo '未找到后端容器' >&2; exit 1; }

docker exec "$db" pg_dump -U watchdog -d watchdog --format=custom > "$work/database.dump"
[[ "$(wc -c < "$work/database.dump")" -gt 1024 ]] || { echo '数据库 dump 过小，疑似失败' >&2; exit 1; }
docker exec "$backend" tar -czf - -C /app/data . > "$work/private-data.tgz"
cp "$root/ota/latest.json" "$work/ota-latest.json"

dump_bytes="$(wc -c < "$work/database.dump")"
data_bytes="$(wc -c < "$work/private-data.tgz")"
{
  echo "created_at=${stamp}"
  echo "db_container=${db}"
  echo "backend_container=${backend}"
  echo "database_dump_bytes=${dump_bytes}"
  echo "private_data_bytes=${data_bytes}"
  echo "database_sha256=$(sha256sum "$work/database.dump" | awk '{print $1}')"
  echo "private_data_sha256=$(sha256sum "$work/private-data.tgz" | awk '{print $1}')"
} > "$work/manifest.txt"

tar -czf "$backups/$archive" -C "$work" .
sha256sum "$backups/$archive" | awk '{print $1"  "$2}'
ls -l "$backups/$archive" | awk '{print $5}'
REMOTE
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "将执行：pg_dump -Fc → /app/data 打包 → 生成 ${BACKUP_ROOT}/backups/${ARCHIVE}"
  info "将拉回本地并校验 sha256，然后只保留最近 ${KEEP} 份 offsite-* 备份"
  step "dry-run 结束"
  exit 0
fi

REMOTE_OUT="$(printf '%s' "$REMOTE_SCRIPT" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$BACKUP_HOST" "bash -s -- '$BACKUP_ROOT' '$STAMP' '$ARCHIVE'")" \
  || die "线上打包失败"
REMOTE_SHA="$(printf '%s\n' "$REMOTE_OUT" | sed -n 1p | awk '{print $1}')"
REMOTE_SIZE="$(printf '%s\n' "$REMOTE_OUT" | sed -n 2p)"
[[ "$REMOTE_SHA" =~ ^[0-9a-f]{64}$ ]] || die "线上未返回有效 sha256"
info "线上包：${ARCHIVE}（${REMOTE_SIZE} 字节，sha256 ${REMOTE_SHA:0:12}…）"

step "拉回本地并校验"
mkdir -p "$BACKUP_DEST"
chmod 700 "$BACKUP_DEST"
TMP_LOCAL="${BACKUP_DEST}/.incoming-${STAMP}.tar.gz"
scp -q "${BACKUP_HOST}:${BACKUP_ROOT}/backups/${ARCHIVE}" "$TMP_LOCAL" || die "下载失败"
LOCAL_SHA=""
if command -v sha256sum >/dev/null 2>&1; then
  LOCAL_SHA="$(sha256sum "$TMP_LOCAL" | awk '{print $1}')"
else
  LOCAL_SHA="$(shasum -a 256 "$TMP_LOCAL" | awk '{print $1}')"
fi
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || { rm -f "$TMP_LOCAL"; die "sha256 不一致（本地 ${LOCAL_SHA}）"; }
# 本地再解一次目录清单，确认三个成员都在，避免"下载成功但内容不全"。
MEMBERS="$(tar -tzf "$TMP_LOCAL" | grep -E '^\./(manifest\.txt|database\.dump|private-data\.tgz|ota-latest\.json)$' | wc -l | tr -d ' ')"
[[ "$MEMBERS" -eq 4 ]] || { rm -f "$TMP_LOCAL"; die "备份包成员不全（${MEMBERS}/4）"; }
mv "$TMP_LOCAL" "${BACKUP_DEST}/${ARCHIVE}"
chmod 600 "${BACKUP_DEST}/${ARCHIVE}"
info "本地：${BACKUP_DEST}/${ARCHIVE}"

step "清理过期副本（保留最近 ${KEEP} 份）"
prune() { # $1=目录（本地绝对路径或 host:path），$2=是否远程
  local listing
  if [[ "$2" == remote ]]; then
    listing="$(ssh -o BatchMode=yes "$BACKUP_HOST" "ls -1t '$1'/offsite-*.tar.gz 2>/dev/null || true")"
  else
    listing="$(ls -1t "$1"/offsite-*.tar.gz 2>/dev/null || true)"
  fi
  local stale
  stale="$(printf '%s\n' "$listing" | sed '/^$/d' | tail -n +$((KEEP + 1)))"
  [[ -z "$stale" ]] && { info "无需清理（${1}）"; return 0; }
  while IFS= read -r old; do
    [[ -z "$old" ]] && continue
    if [[ "$2" == remote ]]; then
      ssh -o BatchMode=yes "$BACKUP_HOST" "rm -f '$old'"
      info "已删除线上：$(basename "$old")"
    else
      rm -f "$old"
      info "已删除本地：$(basename "$old")"
    fi
  done <<< "$stale"
}
prune "$BACKUP_DEST" local
prune "${BACKUP_ROOT}/backups" remote

step "备份完成"
info "本机副本：${BACKUP_DEST}/${ARCHIVE}"
warn "本机副本仍与这台电脑同处一地；重要资料建议再复制到移动硬盘或对象存储"
