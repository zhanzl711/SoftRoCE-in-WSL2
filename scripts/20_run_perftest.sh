#!/usr/bin/env bash
# 跑 perftest：在 rxe 端口之间测 RDMA 带宽 / 消息率。
#
# 自动探测 GID index：rxe 在 RoCEv2 下，第 1 个 GID 通常是 IPv4-mapped 地址
# （形如 ::ffff:192.168.96.110），用错 index 会直接 "Failed to modify QP to RTR"。
set -euo pipefail

TEST="write"        # write | read | send | rdma | all
DURATION=5
SIZE=65536
DEPTH=128
SERVER_DEV="${SERVER_DEV:-rxe0}"
CLIENT_DEV="${CLIENT_DEV:-rxe1}"
SERVER_IP="${SERVER_IP:-192.168.96.100}"
CLIENT_IP="${CLIENT_IP:-192.168.96.110}"
PORT=18515
GID_INDEX=""
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)    TEST="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --size)    SIZE="$2"; shift 2 ;;
    --depth)   DEPTH="$2"; shift 2 ;;
    --server-dev) SERVER_DEV="$2"; shift 2 ;;
    --client-dev) CLIENT_DEV="$2"; shift 2 ;;
    --server-ip)  SERVER_IP="$2"; shift 2 ;;
    --client-ip)  CLIENT_IP="$2"; shift 2 ;;
    --gid-index)  GID_INDEX="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v ib_write_bw >/dev/null 2>&1 || die "缺少 perftest：apt-get install -y perftest"

# ---------- 探测 GID index ----------
detect_gid() {
  local dev="$1"
  local n v
  for g in /sys/class/infiniband/"$dev"/ports/1/gids/*; do
    n=$(basename "$g"); v=$(cat "$g")
    # IPv4-mapped GID 形如 0000:...:0000:ffff:c0a8:6064
    if [[ "$v" == *:ffff:* ]]; then echo "$n"; return 0; fi
  done
  echo 0
}

if [[ -z "$GID_INDEX" ]]; then
  GID_INDEX=$(detect_gid "$CLIENT_DEV")
  log "自动选择 GID index = $GID_INDEX (IPv4-mapped GID)"
fi

# ---------- 前置检查 ----------
for dev in "$SERVER_DEV" "$CLIENT_DEV"; do
  [[ -e "/sys/class/infiniband/$dev" ]] || die "RDMA 设备不存在: $dev（先跑 10_setup_rxe.sh）"
done

if ! ibv_devinfo -d "$SERVER_DEV" 2>/dev/null | grep -q 'PORT_ACTIVE'; then
  die "$SERVER_DEV 端口不是 ACTIVE，先跑 90_diagnose.sh"
fi

# ---------- 执行 ----------
run_one() {
  local kind="$1" bin="$2" extra="${3:-}"
  local srv_log; srv_log=$(mktemp)

  log "=== $kind : $SERVER_DEV -> $CLIENT_DEV (gid=$GID_INDEX, size=$SIZE, ${DURATION}s) ==="

  # server
  if [[ "$kind" == "read" ]]; then
    ib_read_bw -d "$SERVER_DEV" -x "$GID_INDEX" -F --report_gbits -D "$DURATION" $extra >"$srv_log" 2>&1 &
  elif [[ "$kind" == "send" ]]; then
    ib_send_bw -d "$SERVER_DEV" -x "$GID_INDEX" -F --report_gbits -D "$DURATION" $extra >"$srv_log" 2>&1 &
  elif [[ "$kind" == "rdma" ]]; then
    ibv_rc_rdma_bw -d "$SERVER_DEV" -x "$GID_INDEX" -F --report_gbits -D "$DURATION" $extra >"$srv_log" 2>&1 &
  else
    ib_write_bw -d "$SERVER_DEV" -x "$GID_INDEX" -F --report_gbits -D "$DURATION" $extra >"$srv_log" 2>&1 &
  fi
  local srv_pid=$!
  sleep 2

  # client
  local out rc=0
  set +e
  case "$kind" in
    read) out=$(timeout $((DURATION + 20)) ib_read_bw  -d "$CLIENT_DEV" -x "$GID_INDEX" -F --report_gbits -s "$SIZE" "$SERVER_IP" 2>&1) ;;
    send) out=$(timeout $((DURATION + 20)) ib_send_bw  -d "$CLIENT_DEV" -x "$GID_INDEX" -F --report_gbits -s "$SIZE" "$SERVER_IP" 2>&1) ;;
    rdma) out=$(timeout $((DURATION + 20)) ibv_rc_rdma_bw -d "$CLIENT_DEV" -x "$GID_INDEX" -F --report_gbits -s "$SIZE" "$SERVER_IP" 2>&1) ;;
    *)    out=$(timeout $((DURATION + 20)) ib_write_bw -d "$CLIENT_DEV" -x "$GID_INDEX" -F --report_gbits -s "$SIZE" "$SERVER_IP" 2>&1) ;;
  esac
  rc=$?
  set -e
  wait $srv_pid 2>/dev/null || true

  if [[ $rc -ne 0 ]] || grep -qiE 'Failed to modify QP|Unable to Connect' <<<"$out"; then
    warn "$kind 测试失败"
    echo "$out" | grep -iE 'Failed|Unable|error|Mtu|GID index' | head -10
    echo "--- 排障：./scripts/90_diagnose.sh"
    return 1
  fi

  echo "$out" | grep -E '^ *[0-9]+ +[0-9]+ +[0-9.]+' | tail -1
  echo
}

rc_all=0
case "$TEST" in
  write) run_one write  ib_write_bw || rc_all=1 ;;
  read)  run_one read   ib_read_bw  || rc_all=1 ;;
  send)  run_one send   ib_send_bw  || rc_all=1 ;;
  rdma)  run_one rdma   ibv_rc_rdma_bw || rc_all=1 ;;
  all)
    for t in write read send; do run_one "$t" || rc_all=1; done ;;
  *) die "未知 test: $TEST（可选 write | read | send | rdma | all）" ;;
esac

if [[ $rc_all -ne 0 ]]; then
  die "部分测试失败"
fi
log "全部完成。把输出贴到 docs/RESULTS.md 存档。"
