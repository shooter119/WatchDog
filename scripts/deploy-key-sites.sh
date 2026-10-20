#!/usr/bin/env bash
# Backend/admin deployment only. No APK, Git tag, version or OTA publication.
set -euo pipefail
cd "$(dirname "$0")/.."
remote_host="${WATCHDOG_DEPLOY_HOST:-ali}"
remote_root="${WATCHDOG_DEPLOY_ROOT:-/opt/watchdog}"
[[ "$remote_host" =~ ^[A-Za-z0-9_.@:-]+$ && "$remote_root" =~ ^/[A-Za-z0-9_/-]+$ ]] || { echo '部署目标格式无效'; exit 1; }
revision="$(git rev-parse HEAD)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "${1:-}" == '--dry-run' ]]; then
  echo "目标：${remote_host}:${remote_root}；提交：${revision}"
  echo '验证 -> 私有源码/旧镜像备份 -> 构建与Caddy校验 -> 短暂停后端 -> 数据库与私有资料备份 -> 增量迁移与持久卷 -> 健康检查 -> Caddy重载 -> 公网鉴权验收'
  exit 0
fi
[[ -z "$(git status --porcelain)" ]] || { echo '工作区必须为已验证的干净提交'; exit 1; }
logs="$(mktemp -d /tmp/watchdog-deploy.XXXXXX)"
chmod 700 "$logs"
echo "验证日志：$logs"
(cd backend && npm test) > "$logs/backend.log" 2>&1
(cd app && flutter analyze) > "$logs/analyze.log" 2>&1
(cd app && flutter test --reporter json) > "$logs/app.jsonl" 2>&1
node - "$logs" <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const root = process.argv[2], log = fs.readFileSync(`${root}/backend.log`, 'utf8');
assert.ok(Number(/ℹ tests (\d+)/.exec(log)?.[1]) >= 263); assert.match(log, /ℹ fail 0/);
const done = fs.readFileSync(`${root}/app.jsonl`, 'utf8').split('\n').map(line => { try { return JSON.parse(line); } catch { return {}; } });
assert.ok(done.filter(item => item.type === 'testDone' && !item.hidden && !item.skipped).length >= 354);
assert.ok(done.some(item => item.type === 'done' && item.success === true));
assert.match(fs.readFileSync(`${root}/analyze.log`, 'utf8'), /No issues found/);
JS
pre_snapshot="$(node scripts/verify-key-sites.mjs --snapshot)"
git archive --format=tar "$revision" backend deploy/vps/Caddyfile deploy/vps/docker-compose.yml | gzip > "$logs/source.tgz"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" "mkdir -p '$remote_root/backups/key-sites-$stamp' && chmod 700 '$remote_root/backups/key-sites-$stamp'"
scp -q "$logs/source.tgz" "$remote_host:$remote_root/backups/key-sites-$stamp/candidate.tgz"
cat > "$logs/deploy-worker.sh" <<'REMOTE'
set -euo pipefail
umask 077
root="$1"; stamp="$2"; revision="$3"; backup="$root/backups/key-sites-$stamp"
cd "$root"
compose=(docker compose -f deploy/vps/docker-compose.yml)
cid="$("${compose[@]}" ps -q backend)"; caddy="$("${compose[@]}" ps -q caddy)"
[[ -n "$cid" && -n "$caddy" ]] || { echo '现有服务未就绪'; exit 1; }
old_image="$(docker inspect --format '{{.Image}}' "$cid")"
project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid")"
volume="${project}_import-data"
printf '%s\n' "$project" > "$backup/compose-project"
old_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$cid")"
[[ -z "$old_volume" || "$old_volume" == "$volume" ]] || { echo '私有卷名称与预期不一致'; exit 1; }
docker volume create "$volume" >/dev/null
if [[ -z "$old_volume" ]]; then
  docker run --rm -u 0 --entrypoint sh -v "$volume:/restore" "$old_image" -c 'test -z "$(ls -A /restore)"' || { echo '目标私有卷已存在资料，停止以防覆盖'; exit 1; }
fi
tar -czf "$backup/source-before.tgz" backend deploy/vps/Caddyfile deploy/vps/docker-compose.yml
cp deploy/vps/Caddyfile "$backup/Caddyfile.before"
docker image tag "$old_image" "watchdog-backend:before-$stamp"
printf '%s\n' "$old_image" > "$backup/old-image-id"
mkdir "$backup/candidate"
tar -xzf "$backup/candidate.tgz" -C "$backup/candidate"
docker cp "$backup/candidate/deploy/vps/Caddyfile" "$caddy:/tmp/watchdog-$stamp.Caddyfile"
docker exec "$caddy" caddy validate --config "/tmp/watchdog-$stamp.Caddyfile" --adapter caddyfile
docker build --build-arg NODE_IMAGE=docker.m.daocloud.io/library/node:24-bookworm-slim --build-arg DEBIAN_MIRROR=https://mirrors.aliyun.com -t "watchdog-backend:candidate-$stamp" "$backup/candidate/backend"
cp -a "$backup/candidate/backend/." backend/
cp "$backup/candidate/deploy/vps/docker-compose.yml" deploy/vps/docker-compose.yml
cat > "$backup/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
root="$1"; backup="$2"
cd "$root"
compose=(docker compose -f deploy/vps/docker-compose.yml)
project="$(cat "$backup/compose-project")"
caddy="$("${compose[@]}" ps -aq caddy)"
docker image tag "$(cat "$backup/old-image-id")" "${project}-backend"
"${compose[@]}" up -d --no-deps --no-build backend
cat "$backup/Caddyfile.before" > deploy/vps/Caddyfile
host_inode="$(stat -c %i deploy/vps/Caddyfile)"
mounted_inode="$(docker exec "$caddy" stat -c %i /etc/caddy/Caddyfile 2>/dev/null || true)"
if [[ "$host_inode" != "$mounted_inode" ]]; then
  "${compose[@]}" up -d --no-deps --force-recreate caddy
else
  docker exec "$caddy" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
fi
echo '已回切旧镜像及路由，保留增量表与私有卷；未恢复旧数据库覆盖新数据。'
ROLLBACK
chmod 700 "$backup/rollback.sh"
stopped=0; activated=0; changed_caddy=0; finished=0
rollback() {
  trap - ERR EXIT HUP INT TERM
  echo '部署失败，回切旧后端镜像；不删除增量表或私有资料。' >&2
  if [[ "$changed_caddy" == 1 ]]; then
    cat "$backup/Caddyfile.before" > deploy/vps/Caddyfile
    current_caddy="$("${compose[@]}" ps -aq caddy)"
    host_inode="$(stat -c %i deploy/vps/Caddyfile)"
    mounted_inode="$(docker exec "$current_caddy" stat -c %i /etc/caddy/Caddyfile 2>/dev/null || true)"
    if [[ "$host_inode" != "$mounted_inode" ]]; then "${compose[@]}" up -d --no-deps --force-recreate caddy || true
    else docker exec "$current_caddy" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true; fi
  fi
  if [[ "$activated" == 1 ]]; then
    docker image tag "$old_image" "${project}-backend"
    "${compose[@]}" up -d --no-deps --no-build backend || true
  elif [[ "$stopped" == 1 ]]; then docker start "$cid" >/dev/null || true; fi
  exit 1
}
trap rollback ERR HUP INT TERM
trap 'if [[ "$finished" != 1 ]]; then rollback; fi' EXIT
"${compose[@]}" stop backend
stopped=1
"${compose[@]}" exec -T database pg_dump -U watchdog -d watchdog -Fc < /dev/null > "$backup/database.dump"
"${compose[@]}" exec -T database pg_restore --list < "$backup/database.dump" > "$backup/database.contents"
mkdir "$backup/app-data"
docker cp -a "$cid:/app/data/." "$backup/app-data/"
tar -czf "$backup/private-data.tgz" -C "$backup/app-data" .
if [[ -z "$old_volume" ]]; then
  docker run --rm -u 0 --entrypoint sh -v "$volume:/restore" -v "$backup/app-data:/seed:ro" "$old_image" -c 'cp -a /seed/. /restore/ && chown -R 1000:1000 /restore && chmod 700 /restore'
fi
test -s "$backup/database.dump"
test -s "$backup/private-data.tgz"
docker image tag "watchdog-backend:candidate-$stamp" "${project}-backend"
activated=1
"${compose[@]}" up -d --no-deps --no-build backend
healthy=0
for attempt in $(seq 1 40); do
  current="$("${compose[@]}" ps -q backend)"
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$current")"
  if [[ "$status" == healthy ]]; then healthy=1; break; fi
  sleep 2
done
[[ "$healthy" == 1 ]]
docker exec "$current" node -e 'const fs=require("node:fs"),p=require("node:path");const root=p.resolve(process.env.WATCHDOG_DATA_DIR||"/app/data","private-key-sites");fs.mkdirSync(root,{recursive:true,mode:0o700});fs.accessSync(root,fs.constants.W_OK);console.log("private storage writable")'
# Preserve the bind-mounted file inode so Caddy reads the new contents.
cat "$backup/candidate/deploy/vps/Caddyfile" > deploy/vps/Caddyfile
changed_caddy=1
host_inode="$(stat -c %i deploy/vps/Caddyfile)"
mounted_inode="$(docker exec "$caddy" stat -c %i /etc/caddy/Caddyfile 2>/dev/null || true)"
if [[ "$host_inode" != "$mounted_inode" ]]; then
  "${compose[@]}" up -d --no-deps --force-recreate caddy
else
  docker exec "$caddy" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
fi
printf '%s\n' "$revision" > "$backup/deployed-commit"
"${compose[@]}" ps
printf '私有备份：%s\n' "$backup"
finished=1
trap - ERR EXIT HUP INT TERM
REMOTE
scp -q "$logs/deploy-worker.sh" "$remote_host:$remote_root/backups/key-sites-$stamp/deploy-worker.sh"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" "bash '$remote_root/backups/key-sites-$stamp/deploy-worker.sh' '$remote_root' '$stamp' '$revision'" < /dev/null
verified=0
for attempt in $(seq 1 5); do
  if WATCHDOG_PRE_DEPLOY_SNAPSHOT="$pre_snapshot" node scripts/verify-key-sites.mjs > "$logs/public-verification.json" 2> "$logs/public-verification.err"; then
    verified=1
    cat "$logs/public-verification.json"
    break
  fi
  sleep 2
done
if [[ "$verified" != 1 ]]; then
  cat "$logs/public-verification.err" >&2
  echo '公网验收失败，执行保留数据的旧镜像与路由回切。' >&2
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" "bash '$remote_root/backups/key-sites-$stamp/rollback.sh' '$remote_root' '$remote_root/backups/key-sites-$stamp'"
  exit 1
fi
echo "后端部署与匿名公网验证完成；授权扫码、真实资料试点与实机验收仍须分别核实。私有备份：$remote_root/backups/key-sites-$stamp"
