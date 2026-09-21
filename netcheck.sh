#!/usr/bin/env bash

# VPS network benchmark: Ookla Speedtest + iperf3
# License: MIT

set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

SCRIPT_VERSION="1.0.0"
TEST_SECONDS=10
PARALLEL_STREAMS=4
FULL_MODE=1
AUTO_INSTALL=1
USE_COLOR=1
CUSTOM_IPERF=""
SPEEDTEST_VERSION="${SPEEDTEST_VERSION:-1.2.0}"

TMP_DIR=""
SPEEDTEST_JSON=""
SPEEDTEST_ERROR=""
IPERF_ATTEMPT_LOG=""

STATUS_SPEEDTEST_BIN="UNKNOWN"
STATUS_SPEEDTEST_NET="NOT RUN"
STATUS_IPERF_BIN="UNKNOWN"
STATUS_IPERF_NET="NOT RUN"

ST_ISP="—"
ST_IP="—"
ST_SERVER="—"
ST_PING="—"
ST_JITTER="—"
ST_LOSS="—"
ST_DOWNLOAD="—"
ST_UPLOAD="—"
ST_URL="—"

IP4_UP="—"
IP4_DOWN="—"
IP1_UP="—"
IP1_DOWN="—"
IP4_UP_ENDPOINT="—"
IP4_DOWN_ENDPOINT="—"
IP1_UP_ENDPOINT="—"
IP1_DOWN_ENDPOINT="—"

if [[ -t 1 ]]; then
  :
else
  USE_COLOR=0
fi

usage() {
  cat <<'EOF'
VPS Netcheck — Ookla Speedtest + iperf3

Usage:
  vps-netcheck.sh [options]

Options:
  --quick                 Speedtest + iperf3 in 4 streams only
  --full                  Also test one TCP stream (default)
  --duration SECONDS      Duration of each iperf3 test (default: 10)
  --parallel NUMBER       Number of parallel iperf3 streams (default: 4)
  --iperf-server HOST:PORT
                          Use only the specified iperf3 server
  --no-install            Do not install missing dependencies
  --no-color              Disable ANSI colors
  -h, --help              Show this help
  -v, --version           Show version

Environment:
  SPEEDTEST_VERSION       Ookla static CLI version (default: 1.2.0)

Examples:
  sudo bash vps-netcheck.sh
  bash vps-netcheck.sh --quick
  bash vps-netcheck.sh --iperf-server speedtest.serverius.net:5002
EOF
}

while (($#)); do
  case "$1" in
    --quick) FULL_MODE=0; shift ;;
    --full) FULL_MODE=1; shift ;;
    --duration)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --duration" >&2; exit 2; }
      TEST_SECONDS="$2"; shift 2 ;;
    --parallel)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --parallel" >&2; exit 2; }
      PARALLEL_STREAMS="$2"; shift 2 ;;
    --iperf-server)
      [[ $# -ge 2 && "$2" == *:* ]] || { echo "Use HOST:PORT after --iperf-server" >&2; exit 2; }
      CUSTOM_IPERF="$2"; shift 2 ;;
    --no-install) AUTO_INSTALL=0; shift ;;
    --no-color) USE_COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "vps-netcheck $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ((USE_COLOR)); then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
else
  C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM=""
fi

info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s[XX]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t vps-netcheck)"
SPEEDTEST_JSON="$TMP_DIR/speedtest.json"
SPEEDTEST_ERROR="$TMP_DIR/speedtest.err"
IPERF_ATTEMPT_LOG="$TMP_DIR/iperf-attempts.log"

run_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 126
  fi
}

have_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || command -v sudo >/dev/null 2>&1
}

detect_pkg_manager() {
  local manager
  for manager in apt-get dnf yum apk pacman zypper; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s' "$manager"
      return 0
    fi
  done
  return 1
}

install_packages() {
  local manager="$1"
  shift
  case "$manager" in
    apt-get)
      run_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt update завершился с предупреждением; пробую установить из текущего кэша"
      run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
      ;;
    dnf) run_root dnf install -y -q "$@" ;;
    yum) run_root yum install -y -q "$@" ;;
    apk) run_root apk add --no-progress "$@" ;;
    pacman) run_root pacman -Sy --noconfirm --needed "$@" ;;
    zypper) run_root zypper --non-interactive install "$@" ;;
    *) return 1 ;;
  esac
}

ensure_base_tools() {
  local missing=() manager
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v timeout >/dev/null 2>&1 || missing+=(coreutils)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  ((${#missing[@]} == 0)) && return 0

  if ((AUTO_INSTALL == 0)); then
    fail "Не хватает: ${missing[*]} (автоустановка отключена)"
    return 1
  fi
  have_root || { fail "Для установки ${missing[*]} нужны root-права или sudo"; return 1; }
  manager="$(detect_pkg_manager)" || { fail "Не найден поддерживаемый пакетный менеджер"; return 1; }
  info "Устанавливаю служебные зависимости: ${missing[*]}"
  install_packages "$manager" "${missing[@]}"
}

is_ookla_speedtest() {
  command -v speedtest >/dev/null 2>&1 || return 1
  speedtest --version 2>&1 | grep -qiE 'ookla|speedtest by ookla'
}

install_speedtest() {
  local machine archive_arch url archive extract_dir binary
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) archive_arch="x86_64" ;;
    aarch64|arm64) archive_arch="aarch64" ;;
    armv7l|armv7*) archive_arch="armhf" ;;
    i386|i486|i586|i686) archive_arch="i386" ;;
    *) fail "Ookla CLI: архитектура $machine не поддерживается автоустановкой"; return 1 ;;
  esac

  have_root || { fail "Для установки Ookla Speedtest нужны root-права или sudo"; return 1; }
  archive="$TMP_DIR/ookla-speedtest.tgz"
  extract_dir="$TMP_DIR/ookla-speedtest"
  mkdir -p "$extract_dir"
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VERSION}-linux-${archive_arch}.tgz"
  info "Устанавливаю официальный Ookla Speedtest CLI ${SPEEDTEST_VERSION}"
  curl -fL --connect-timeout 10 --max-time 90 --retry 2 -o "$archive" "$url" || {
    fail "Не удалось скачать Ookla Speedtest CLI"
    return 1
  }
  tar -xzf "$archive" -C "$extract_dir" || { fail "Не удалось распаковать Ookla CLI"; return 1; }
  binary="$extract_dir/speedtest"
  [[ -x "$binary" ]] || { fail "В архиве Ookla не найден исполняемый файл speedtest"; return 1; }
  run_root install -m 0755 "$binary" /usr/local/bin/speedtest
  hash -r
}

ensure_speedtest() {
  if is_ookla_speedtest; then
    STATUS_SPEEDTEST_BIN="OK"
    ok "Ookla Speedtest CLI уже установлен: $(speedtest --version 2>&1 | head -n1)"
    return 0
  fi

  if command -v speedtest >/dev/null 2>&1; then
    warn "Команда speedtest найдена, но это не официальный Ookla CLI"
  else
    warn "Ookla Speedtest CLI не установлен"
  fi

  if ((AUTO_INSTALL == 0)); then
    STATUS_SPEEDTEST_BIN="MISSING"
    return 1
  fi
  if install_speedtest && is_ookla_speedtest; then
    STATUS_SPEEDTEST_BIN="INSTALLED"
    ok "Ookla Speedtest CLI установлен"
    return 0
  fi
  STATUS_SPEEDTEST_BIN="INSTALL FAILED"
  return 1
}

ensure_iperf3() {
  local manager
  if command -v iperf3 >/dev/null 2>&1; then
    STATUS_IPERF_BIN="OK"
    ok "iperf3 уже установлен: $(iperf3 --version 2>&1 | head -n1)"
    return 0
  fi
  warn "iperf3 не установлен"
  if ((AUTO_INSTALL == 0)); then
    STATUS_IPERF_BIN="MISSING"
    return 1
  fi
  have_root || { STATUS_IPERF_BIN="INSTALL FAILED"; fail "Для установки iperf3 нужны root-права или sudo"; return 1; }
  manager="$(detect_pkg_manager)" || { STATUS_IPERF_BIN="INSTALL FAILED"; fail "Не найден поддерживаемый пакетный менеджер"; return 1; }
  info "Устанавливаю iperf3"
  if install_packages "$manager" iperf3 && command -v iperf3 >/dev/null 2>&1; then
    STATUS_IPERF_BIN="INSTALLED"
    ok "iperf3 установлен"
    return 0
  fi
  STATUS_IPERF_BIN="INSTALL FAILED"
  fail "Не удалось установить iperf3"
  return 1
}

classify_speedtest_error() {
  local text
  text="$(tr '\n' ' ' < "$SPEEDTEST_ERROR")"
  if grep -qiE '403|451|forbidden|access denied|blocked|banned|not available in your region' <<<"$text"; then
    STATUS_SPEEDTEST_NET="BLOCKED/RESTRICTED"
  elif grep -qiE 'timed out|timeout' <<<"$text"; then
    STATUS_SPEEDTEST_NET="TIMEOUT"
  elif grep -qiE 'resolve|name resolution|temporary failure in name resolution' <<<"$text"; then
    STATUS_SPEEDTEST_NET="DNS ERROR"
  elif grep -qiE 'configuration|socket|connect|network|server' <<<"$text"; then
    STATUS_SPEEDTEST_NET="UNAVAILABLE"
  else
    STATUS_SPEEDTEST_NET="ERROR"
  fi
}

run_speedtest() {
  local rc=0
  section "2. Ookla Speedtest"
  [[ "$STATUS_SPEEDTEST_BIN" == "OK" || "$STATUS_SPEEDTEST_BIN" == "INSTALLED" ]] || {
    STATUS_SPEEDTEST_NET="NOT TESTED"
    warn "Тест пропущен: официальный Ookla CLI недоступен"
    return 1
  }

  info "Проверяю доступ к Speedtest и измеряю скорость (до 120 секунд)"
  timeout 120 speedtest --accept-license --accept-gdpr --progress=no --format=json \
    >"$SPEEDTEST_JSON" 2>"$SPEEDTEST_ERROR" || rc=$?

  if [[ $rc -eq 0 ]] && jq -e '.download.bandwidth and .upload.bandwidth' "$SPEEDTEST_JSON" >/dev/null 2>&1; then
    STATUS_SPEEDTEST_NET="AVAILABLE"
    ST_ISP="$(jq -r '.isp // "—"' "$SPEEDTEST_JSON")"
    ST_IP="$(jq -r '.interface.externalIp // "—"' "$SPEEDTEST_JSON")"
    ST_SERVER="$(jq -r '[.server.name, .server.location, .server.country] | map(select(. != null and . != "")) | join(", ")' "$SPEEDTEST_JSON")"
    ST_PING="$(jq -r 'if .ping.latency == null then "—" else (.ping.latency | tostring) end' "$SPEEDTEST_JSON")"
    ST_JITTER="$(jq -r 'if .ping.jitter == null then "—" else (.ping.jitter | tostring) end' "$SPEEDTEST_JSON")"
    ST_LOSS="$(jq -r 'if .packetLoss == null then "—" else (.packetLoss | tostring) end' "$SPEEDTEST_JSON")"
    ST_DOWNLOAD="$(jq -r '(.download.bandwidth * 8 / 1000000 * 100 | round / 100) | tostring' "$SPEEDTEST_JSON")"
    ST_UPLOAD="$(jq -r '(.upload.bandwidth * 8 / 1000000 * 100 | round / 100) | tostring' "$SPEEDTEST_JSON")"
    ST_URL="$(jq -r '.result.url // "—"' "$SPEEDTEST_JSON")"
    ok "Speedtest доступен; тест завершён"
    return 0
  fi

  if [[ $rc -eq 124 ]]; then
    printf 'Test timed out after 120 seconds\n' >>"$SPEEDTEST_ERROR"
  fi
  [[ -s "$SPEEDTEST_JSON" ]] && cat "$SPEEDTEST_JSON" >>"$SPEEDTEST_ERROR"
  classify_speedtest_error
  fail "Speedtest не завершён: $STATUS_SPEEDTEST_NET"
  [[ -s "$SPEEDTEST_ERROR" ]] && printf '%s%s%s\n' "$C_DIM" "$(tail -n3 "$SPEEDTEST_ERROR" | tr '\n' ' ')" "$C_RESET"
  return 1
}

build_endpoints() {
  if [[ -n "$CUSTOM_IPERF" ]]; then
    printf '%s\n' "$CUSTOM_IPERF"
    return
  fi
  cat <<'EOF'
speedtest.init7.net:5201
speedtest.init7.net:5202
speedtest.init7.net:5203
speedtest.serverius.net:5002
ping.online.net:5200
ping.online.net:5201
ping.online.net:5202
iperf3.moji.fr:5200
iperf3.moji.fr:5201
iperf3.moji.fr:5202
speedtest.milkywan.fr:9200
speedtest.milkywan.fr:9201
speedtest.milkywan.fr:9202
EOF
}

iperf_error_kind() {
  local file="$1"
  if grep -qiE 'busy running a test|server is busy' "$file"; then printf 'BUSY'
  elif grep -qiE 'connection refused' "$file"; then printf 'REFUSED'
  elif grep -qiE 'timed out|timeout' "$file"; then printf 'TIMEOUT'
  elif grep -qiE 'unable to connect|network is unreachable|no route|operation not permitted' "$file"; then printf 'NETWORK/FILTER'
  elif grep -qiE 'name or service not known|temporary failure|resolve' "$file"; then printf 'DNS'
  else printf 'ERROR'
  fi
}

run_one_iperf() {
  local direction="$1" streams="$2" output_var="$3" endpoint_var="$4"
  local endpoint host port json err probe_err probe_rc rc value kind reverse_args=()
  local -a endpoints=()
  mapfile -t endpoints < <(build_endpoints)
  [[ "$direction" == "DOWN" ]] && reverse_args=(-R)

  for endpoint in "${endpoints[@]}"; do
    host="${endpoint%:*}"
    port="${endpoint##*:}"
    json="$TMP_DIR/iperf-${direction}-${streams}-${host//[^a-zA-Z0-9]/_}-${port}.json"
    err="$json.err"
    probe_err="$json.probe.err"
    probe_rc=0
    timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>"$probe_err" || probe_rc=$?
    if [[ $probe_rc -ne 0 ]]; then
      [[ $probe_rc -eq 124 ]] && printf 'timeout\n' >>"$probe_err"
      kind="$(iperf_error_kind "$probe_err")"
      printf '%s %s streams=%s endpoint=%s\n' "$direction" "$kind" "$streams" "$endpoint" >>"$IPERF_ATTEMPT_LOG"
      continue
    fi
    rc=0
    timeout "$((TEST_SECONDS + 10))" iperf3 -c "$host" -p "$port" -P "$streams" \
      -t "$TEST_SECONDS" -J "${reverse_args[@]}" >"$json" 2>"$err" || rc=$?
    [[ -s "$json" ]] && jq -r '.error // empty' "$json" >>"$err" 2>/dev/null || true

    if [[ $rc -eq 0 ]] && jq -e '.end.sum_received.bits_per_second' "$json" >/dev/null 2>&1; then
      value="$(jq -r '(.end.sum_received.bits_per_second / 1000000 * 100 | round / 100) | tostring' "$json")"
      printf -v "$output_var" '%s' "$value"
      printf -v "$endpoint_var" '%s' "$endpoint"
      ok "iperf3 $direction, ${streams} поток(а): ${value} Мбит/с — $endpoint"
      return 0
    fi

    if [[ $rc -eq 124 ]]; then
      printf 'timeout\n' >>"$err"
    fi
    kind="$(iperf_error_kind "$err")"
    printf '%s %s streams=%s endpoint=%s\n' "$direction" "$kind" "$streams" "$endpoint" >>"$IPERF_ATTEMPT_LOG"
  done
  warn "iperf3 $direction, ${streams} поток(а): ни одна точка не приняла тест"
  return 1
}

classify_iperf_access() {
  [[ -s "$IPERF_ATTEMPT_LOG" ]] || { STATUS_IPERF_NET="AVAILABLE"; return; }
  if grep -qE ' AVAILABLE ' "$IPERF_ATTEMPT_LOG"; then
    STATUS_IPERF_NET="AVAILABLE"
  elif grep -qE 'BUSY|REFUSED' "$IPERF_ATTEMPT_LOG"; then
    STATUS_IPERF_NET="SERVERS BUSY/REFUSED"
  elif grep -qE 'NETWORK/FILTER|TIMEOUT' "$IPERF_ATTEMPT_LOG"; then
    STATUS_IPERF_NET="POSSIBLE FILTER/TIMEOUT"
  elif grep -q 'DNS' "$IPERF_ATTEMPT_LOG"; then
    STATUS_IPERF_NET="DNS ERROR"
  else
    STATUS_IPERF_NET="ERROR"
  fi
}

run_iperf_tests() {
  local successes=0 total=2
  section "3. iperf3"
  [[ "$STATUS_IPERF_BIN" == "OK" || "$STATUS_IPERF_BIN" == "INSTALLED" ]] || {
    STATUS_IPERF_NET="NOT TESTED"
    warn "Тест пропущен: iperf3 недоступен"
    return 1
  }

  info "Ищу доступную публичную точку и запускаю TCP-тесты по ${TEST_SECONDS} секунд"
  run_one_iperf UP "$PARALLEL_STREAMS" IP4_UP IP4_UP_ENDPOINT && ((successes+=1))
  run_one_iperf DOWN "$PARALLEL_STREAMS" IP4_DOWN IP4_DOWN_ENDPOINT && ((successes+=1))
  if ((FULL_MODE)); then
    total=4
    run_one_iperf UP 1 IP1_UP IP1_UP_ENDPOINT && ((successes+=1))
    run_one_iperf DOWN 1 IP1_DOWN IP1_DOWN_ENDPOINT && ((successes+=1))
  fi

  if ((successes > 0)); then
    STATUS_IPERF_NET="AVAILABLE ($successes/$total)"
  else
    classify_iperf_access
  fi
  ((successes > 0))
}

os_name() {
  if [[ -r /etc/os-release ]]; then
    local PRETTY_NAME="" NAME="" VERSION=""
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}"
  else
    uname -s
  fi
}

memory_total() {
  awk '/MemTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || printf '—'
}

status_colored() {
  case "$1" in
    OK|INSTALLED|AVAILABLE*) printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" ;;
    *BLOCKED*|*FILTER*|*FAILED*|ERROR) printf '%s%s%s' "$C_RED" "$1" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" ;;
  esac
}

print_row() {
  printf '  %s %s\n' "$1" "$2"
}

numeric_min() {
  awk -v a="$1" -v b="$2" 'BEGIN {if (a+0 < b+0) print a; else print b}'
}

rating_for() {
  awk -v n="$1" 'BEGIN {
    if (n >= 900) print "отличный (уровень гигабитного порта)";
    else if (n >= 500) print "очень хороший";
    else if (n >= 100) print "хороший";
    else if (n >= 50) print "средний";
    else print "низкий";
  }'
}

print_summary() {
  local cpu_count kernel arch base="" rating="" ratio=""
  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '—')"
  kernel="$(uname -r)"
  arch="$(uname -m)"

  section "ИТОГОВАЯ КАРТИНА"
  print_row "Хост:" "$(hostname 2>/dev/null || printf '—')"
  print_row "ОС:" "$(os_name)"
  print_row "Ядро / архитектура:" "$kernel / $arch"
  print_row "vCPU / RAM:" "$cpu_count / $(memory_total)"
  printf '\n'
  print_row "Ookla CLI:" "$(status_colored "$STATUS_SPEEDTEST_BIN")"
  print_row "Доступ к Speedtest:" "$(status_colored "$STATUS_SPEEDTEST_NET")"
  print_row "iperf3:" "$(status_colored "$STATUS_IPERF_BIN")"
  print_row "Доступ к iperf3:" "$(status_colored "$STATUS_IPERF_NET")"

  if [[ "$STATUS_SPEEDTEST_NET" == "AVAILABLE" ]]; then
    printf '\n%sOokla Speedtest%s\n' "$C_BOLD" "$C_RESET"
    print_row "Провайдер / внешний IP:" "$ST_ISP / $ST_IP"
    print_row "Тестовый сервер:" "$ST_SERVER"
    print_row "Ping / jitter:" "$ST_PING мс / $ST_JITTER мс"
    print_row "Потери пакетов:" "$ST_LOSS %"
    print_row "Download:" "${C_GREEN}${ST_DOWNLOAD} Мбит/с${C_RESET}"
    print_row "Upload:" "${C_GREEN}${ST_UPLOAD} Мбит/с${C_RESET}"
    [[ "$ST_URL" != "—" ]] && print_row "Результат:" "$ST_URL"
  fi

  if [[ "$STATUS_IPERF_NET" == AVAILABLE* ]]; then
    printf '\n%siperf3 TCP%s\n' "$C_BOLD" "$C_RESET"
    print_row "${PARALLEL_STREAMS} потока, upload:" "$IP4_UP Мбит/с  [$IP4_UP_ENDPOINT]"
    print_row "${PARALLEL_STREAMS} потока, download:" "$IP4_DOWN Мбит/с  [$IP4_DOWN_ENDPOINT]"
    if ((FULL_MODE)); then
      print_row "1 поток, upload:" "$IP1_UP Мбит/с  [$IP1_UP_ENDPOINT]"
      print_row "1 поток, download:" "$IP1_DOWN Мбит/с  [$IP1_DOWN_ENDPOINT]"
    fi
  fi

  printf '\n%sВывод%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$ST_DOWNLOAD" != "—" && "$ST_UPLOAD" != "—" ]]; then
    base="$(numeric_min "$ST_DOWNLOAD" "$ST_UPLOAD")"
    rating="$(rating_for "$base")"
    printf '  Канал по Ookla: %s%s%s; ориентир по слабейшему направлению — %s Мбит/с.\n' "$C_BOLD" "$rating" "$C_RESET" "$base"
  else
    printf '  Ookla не дал измерение. Статус выше помогает отличить блокировку, DNS, таймаут и ошибку установки.\n'
  fi

  if [[ "$IP4_UP" != "—" || "$IP4_DOWN" != "—" ]]; then
    printf '  iperf3 подтвердил пропускную способность обычного TCP вне сети Ookla.\n'
  else
    printf '  Ни один публичный iperf3-тест не завершился. Это не доказывает блокировку: публичные слоты часто заняты или временно закрыты.\n'
  fi

  if [[ "$IP1_DOWN" != "—" && "$IP4_DOWN" != "—" ]]; then
    ratio="$(awk -v multi="$IP4_DOWN" -v single="$IP1_DOWN" 'BEGIN {if (single > 0) printf "%.2f", multi/single; else print "0"}')"
    if awk -v r="$ratio" 'BEGIN {exit !(r >= 2.5)}'; then
      printf '  Download в несколько потоков в %s раза быстрее одного: один TCP-сеанс/один VPN-клиент может быть ограничен маршрутом или TCP.\n' "$ratio"
    else
      printf '  Один TCP-поток близок к многопоточному результату — хороший признак для одного VPN-клиента.\n'
    fi
  fi

  printf '\n%sПримечание:%s Ookla и iperf3 используют разные серверы и маршруты, поэтому их цифры не обязаны совпадать.\n' "$C_DIM" "$C_RESET"
}

printf '%sVPS NETCHECK v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
printf 'Ookla Speedtest + iperf3, %s / %s поток(а)\n' "${TEST_SECONDS}s" "$PARALLEL_STREAMS"

section "1. Проверка инструментов"
BASE_TOOLS_OK=1
ensure_base_tools || BASE_TOOLS_OK=0

if ((BASE_TOOLS_OK)); then
  ensure_speedtest || true
else
  STATUS_SPEEDTEST_BIN="DEPENDENCY ERROR"
fi
ensure_iperf3 || true

if ((BASE_TOOLS_OK)); then
  run_speedtest || true
  run_iperf_tests || true
else
  STATUS_SPEEDTEST_NET="NOT TESTED"
  STATUS_IPERF_NET="NOT TESTED"
fi

print_summary

if [[ "$STATUS_SPEEDTEST_NET" == "AVAILABLE" || "$STATUS_IPERF_NET" == AVAILABLE* ]]; then
  exit 0
fi
exit 1
