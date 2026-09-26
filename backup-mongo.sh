#!/usr/bin/env bash
# Дамп базы из env/backend.env. Один контейнер mongo:7, compose не вызывается.
# URI лежит в файле 0600, mongodump читает его через --config: пароля нет ни в логе, ни в argv.
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT}/env/backend.env"
BACKUP_ROOT="${ROOT}/backups"
DAILY="${BACKUP_ROOT}/daily"
WEEKLY="${BACKUP_ROOT}/weekly"
STAMP="$(date +%F)"
ARCHIVE="${DAILY}/${STAMP}.archive.gz"
PARTIAL="${DAILY}/.${STAMP}.archive.gz.partial"
CONF=""
LOG=""

if [[ "$(id -un)" != "scribo" ]]; then
  echo "backup-mongo: запускать от пользователя scribo" >&2
  exit 1
fi

cleanup() {
  local status=$?
  [[ -n "$CONF" ]] && rm -f -- "$CONF"
  [[ -n "$LOG" ]] && rm -f -- "$LOG"
  [[ -n "$PARTIAL" ]] && rm -f -- "$PARTIAL"
  exit "$status"
}
trap cleanup EXIT

umask 077
mkdir -p "$DAILY" "$WEEKLY"
chmod 700 "$BACKUP_ROOT" "$DAILY" "$WEEKLY"

exec 9>"${BACKUP_ROOT}/.lock"
if ! flock -n 9; then
  echo "backup-mongo: другой дамп ещё идёт" >&2
  exit 1
fi

read_env() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" | tail -n 1 || true)"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line#export}"
  line="${line#"${line%%[![:space:]]*}"}"
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

urlencode() {
  local LC_ALL=C
  local s="$1" i c code hex out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~!*\'\(\)-]) out+="$c" ;;
      *)
        printf -v code '%d' "'$c"
        printf -v hex '%%%02X' "$((code & 255))"
        out+="$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

normalize_host() {
  local raw="$1"
  raw="${raw#mongodb+srv://}"
  raw="${raw#mongodb://}"
  raw="${raw%%/*}"
  raw="${raw%%\?*}"
  printf '%s' "$raw"
}

iso_days_ago() {
  local n="$1"
  if date --version >/dev/null 2>&1; then
    date -d "${n} days ago" +%F
  else
    date -v-"${n}"d +%F
  fi
}

redact() {
  sed -E 's#mongodb(\+srv)?://[^[:space:]]*@#mongodb\1://***@#g'
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "backup-mongo: нет файла env/backend.env" >&2
  exit 1
fi

DB_USER="$(read_env DB_USER)"
DB_PASSWORD="$(read_env DB_PASSWORD)"
DB_HOST="$(normalize_host "$(read_env DB_HOST)")"
DB_NAME="$(read_env DB_NAME)"

if [[ -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" || -z "$DB_NAME" ]]; then
  echo "backup-mongo: в env/backend.env нужны DB_USER, DB_PASSWORD, DB_HOST, DB_NAME" >&2
  exit 1
fi

uri="mongodb+srv://$(urlencode "$DB_USER"):$(urlencode "$DB_PASSWORD")@${DB_HOST}/$(urlencode "$DB_NAME")?retryWrites=true&w=majority"
unset DB_PASSWORD

CONF="$(mktemp "${BACKUP_ROOT}/.uri.XXXXXX")"
chmod 600 "$CONF"
printf "uri: '%s'\n" "$uri" >"$CONF"
unset uri

LOG="$(mktemp "${BACKUP_ROOT}/.log.XXXXXX")"
chmod 600 "$LOG"
rm -f -- "$PARTIAL"

docker_status=0
docker run --rm \
  --entrypoint /usr/bin/mongodump \
  -v "${CONF}:/dump.conf:ro" \
  mongo:7 \
  --config=/dump.conf \
  --gzip \
  --archive \
  --numParallelCollections=1 \
  >"$PARTIAL" 2>"$LOG" || docker_status=$?

redact <"$LOG" >&2 || true
rm -f -- "$LOG"
LOG=""

if [[ "$docker_status" -ne 0 ]]; then
  echo "backup-mongo: mongodump завершился с кодом ${docker_status}" >&2
  exit "$docker_status"
fi

if [[ ! -s "$PARTIAL" ]] || ! gzip -t "$PARTIAL"; then
  echo "backup-mongo: архив пустой или повреждён" >&2
  exit 1
fi

mv -f -- "$PARTIAL" "$ARCHIVE"
PARTIAL=""
chmod 600 "$ARCHIVE"
echo "backup-mongo: ${ARCHIVE}"

if [[ "$(date +%u)" == "7" ]]; then
  weekly="${WEEKLY}/${STAMP}.archive.gz"
  cp -f -- "$ARCHIVE" "$weekly"
  chmod 600 "$weekly"
  echo "backup-mongo: ${weekly}"
fi

is_older() {
  [[ "$1" < "$2" ]]
}

prune_before() {
  local dir="$1" cutoff="$2" file name
  shopt -s nullglob
  for file in "$dir"/*.archive.gz; do
    name="$(basename "$file" .archive.gz)"
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    if LC_ALL=C is_older "$name" "$cutoff"; then
      rm -f -- "$file"
    fi
  done
  shopt -u nullglob
}

prune_before "$DAILY" "$(iso_days_ago 30)"
prune_before "$WEEKLY" "$(iso_days_ago 365)"
rm -f -- "$CONF"
CONF=""
