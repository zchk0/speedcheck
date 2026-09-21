#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${TEST_PORT:-55201}"
OUTPUT="$(mktemp)"
LISTENER_PID=""

cleanup() {
  [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null || true
  rm -f -- "$OUTPUT"
}
trap cleanup EXIT

python3 - "$PORT" <<'PY' &
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    while True:
        conn, _ = sock.accept()
        conn.close()
PY
LISTENER_PID=$!

for _ in 1 2 3 4 5; do
  if bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$PORT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

PATH="$ROOT_DIR/tests/fixtures/bin:$PATH" \
  bash "$ROOT_DIR/speedcheck.sh" --no-install --quick --duration 1 \
  --iperf-server "127.0.0.1:$PORT" --no-color >"$OUTPUT"

grep -q 'Доступ к Speedtest: AVAILABLE' "$OUTPUT"
grep -q 'Доступ к iperf3: AVAILABLE (2/2)' "$OUTPUT"
grep -q 'Download: 930 Мбит/с' "$OUTPUT"
grep -q '4 потока, upload: 895.5 Мбит/с' "$OUTPUT"

echo "smoke test: OK"
