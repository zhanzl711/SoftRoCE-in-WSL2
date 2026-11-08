#!/usr/bin/env bash
# soft-roce-lab: 在 WSL2 / Linux 上用 Soft-RoCE (rxe) 搭一个可复现的 RDMA 测试床。
#
# 关键事实（本仓库实测得出，见 docs/TROUBLESHOOTING.md）：
#   rxe 端口 MTU 由底层 netdev 的 MTU 推导，不是独立设置项。
#   netdev mtu=1500 -> rxe active_mtu=1024
#   netdev mtu=4150 -> rxe active_mtu=2048
#   netdev mtu=4600 -> rxe active_mtu=4096   <-- 推荐值
#
# 用法:
#   ./scripts/10_setup_rxe.sh                 # 建 veth 对 + 两个 rxe 端口
#   ./scripts/10_setup_rxe.sh --mode single   # 只建一个 rxe 绑到现有网卡
#   ./scripts/10_setup_rxe.sh --teardown       # 清理
set -euo pipefail

# ---------- 参数 ----------
MODE="veth"          # veth | single
MTU=4600             # 底层 netdev MTU；4600 -> rxe active_mtu 4096
NETDEV_A="veth0"     # server 侧
NETDEV_B="veth1"     # client 侧
IP_A="192.168.96.100"
IP_B="192.168.96.110"
RDE_A="rxe0"         # server 侧 RDMA 设备
RDE_B="rxe1"         # client 侧 RDMA 设备
TEARDOWN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)     MODE="$2"; shift 2 ;;
    --mtu)      MTU="$2"; shift 2 ;;
    --netdev-a) NETDEV_A="$2"; shift 2 ;;
    --netdev-b) NETDEV_B="$2"; shift 2 ;;
    --ip-a)     IP_A="$2"; shift 2 ;;
    --ip-b)     IP_B="$2"; shift 2 ;;
    --rde-a)    RDE_A="$2"; shift 2 ;;
    --rde-b)    RDE_B="$2"; shift 2 ;;
    --teardown) TEARDOWN=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# `rdma link show <dev>` 在部分 iproute2 版本会报 "Wrong device name"，
# 必须从全量输出里按 "link <dev>/<port>" 匹配。
rd_exists() {
  rdma link show 2>/dev/null | grep -qE "^link $1/"
}
rd_netdev() {
  rdma link show 2>/dev/null | grep -E "^link $1/" | grep -o 'netdev [a-z0-9]*' | awk '{print $2}'
}

[[ $EUID -eq 0 ]] || die "需要 root（用 sudo bash ... 或在 WSL 里 sudo -u root）"

# ---------- 依赖 ----------
need_mod() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1（先跑 scripts/00_install.sh）"
}
need_mod ip
need_mod rdma
need_mod sysctl

load_rxe() {
  if ! lsmod | grep -q '^rdma_rxe'; then
    modprobe rdma_rxe 2>/dev/null || true
  fi
  lsmod | grep -q '^rdma_rxe' || die "rdma_rxe 模块未加载：modprobe rdma_rxe 失败（WSL2 需要内核带 CONFIG_INFINIBAND_RXE）"
}

# ---------- 清理 ----------
# 若目标 RDMA 设备名已被"别的"底层网卡占用，拒绝破坏别人的配置。
prepare_rde() {
  local rde="$1" want="$2"
  if rd_exists "$rde"; then
    local cur
    cur=$(rd_netdev "$rde")
    if [[ -n "$cur" && "$cur" != "$want" ]]; then
      die "$rde 已经绑定在 $cur 上，与本次目标 $want 不一致。
       为避免破坏你已有的配置，请换一个设备名，例如：
         ./scripts/10_setup_rxe.sh --rde-a rxe1 --rde-b rxe2"
    fi
    log "  复用并重建 $rde (原绑定 ${cur:-未知})"
    rdma link delete "$rde" 2>/dev/null || true
  fi
}

teardown() {
  log "清理中..."
  for rd in "$RDE_A" "$RDE_B"; do
    if rd_exists "$rd"; then
      rdma link delete "$rd" 2>/dev/null || true
      log "  删除 RDMA 设备 $rd"
    fi
  done
  for nd in "$NETDEV_A" "$NETDEV_B"; do
    if ip link show "$nd" >/dev/null 2>&1; then
      ip link del "$nd" 2>/dev/null || true
      log "  删除 netdev $nd"
    fi
  done
  log "清理完成"
}

if [[ $TEARDOWN -eq 1 ]]; then teardown; exit 0; fi

load_rxe

# ---------- 建端口 ----------
if [[ "$MODE" == "veth" ]]; then
  # 先清掉旧的，保证幂等（prepare_rde 会保护"绑定在别的网卡上"的设备）
  prepare_rde "$RDE_A" "$NETDEV_A"
  prepare_rde "$RDE_B" "$NETDEV_B"
  ip link del "$NETDEV_A" 2>/dev/null || true

  log "创建 veth 对: $NETDEV_A <-> $NETDEV_B (mtu=$MTU)"
  ip link add "$NETDEV_A" type veth peer name "$NETDEV_B"
  ip link set "$NETDEV_A" mtu "$MTU"
  ip link set "$NETDEV_B" mtu "$MTU"
  ip link set "$NETDEV_A" up
  ip link set "$NETDEV_B" up

  log "配置地址: $NETDEV_A=$IP_A  $NETDEV_B=$IP_B"
  ip addr replace "$IP_A/24" dev "$NETDEV_A"
  ip addr replace "$IP_B/24" dev "$NETDEV_B"

  log "创建 RDMA 设备: $RDE_A -> $NETDEV_A, $RDE_B -> $NETDEV_B"
  rdma link add "$RDE_A" type rxe netdev "$NETDEV_A"
  rdma link add "$RDE_B" type rxe netdev "$NETDEV_B"

  # RoCEv2 在同一子网内回环需要放行本地地址
  for nd in "$NETDEV_A" "$NETDEV_B"; do
    sysctl -qw "net.ipv4.conf.$nd.accept_local=1"
    sysctl -qw "net.ipv4.conf.$nd.rp_filter=0"
  done

  CLIENT_IP="$IP_B"
  SERVER_IP="$IP_A"
  SERVER_DEV="$RDE_A"
  CLIENT_DEV="$RDE_B"

elif [[ "$MODE" == "single" ]]; then
  BASE_NETDEV="${NETDEV_A}"
  [[ -e "/sys/class/net/$BASE_NETDEV" ]] || die "netdev 不存在: $BASE_NETDEV"
  prepare_rde "$RDE_A" "$BASE_NETDEV"
  log "创建 RDMA 设备: $RDE_A -> $BASE_NETDEV (mtu 设为 $MTU)"
  ip link set "$BASE_NETDEV" mtu "$MTU"
  ip link set "$BASE_NETDEV" up
  rdma link add "$RDE_A" type rxe netdev "$BASE_NETDEV"

  CLIENT_IP="$IP_A"
  SERVER_IP="$IP_A"
  SERVER_DEV="$RDE_A"
  CLIENT_DEV="$RDE_A"
  warn "single 模式：client/server 在同一设备上，仅用于验证链路，不代表真实带宽"
else
  die "未知 mode: $MODE（可选 veth | single）"
fi

sleep 1

# ---------- 校验 ----------
echo
log "===== 状态 ====="
rdma link show
echo
for rd in "$SERVER_DEV" "$CLIENT_DEV"; do
  [[ -e "/sys/class/infiniband/$rd" ]] || continue
  amtu=$(ibv_devinfo -d "$rd" 2>/dev/null | awk '/active_mtu/{print $2}')
  mmtu=$(ibv_devinfo -d "$rd" 2>/dev/null | awk '/max_mtu/{print $2}')
  state=$(ibv_devinfo -d "$rd" 2>/dev/null | awk -F': *' '/state:/{print $2}')
  printf '  %-8s state=%-18s active_mtu=%-6s max_mtu=%s\n' "$rd" "$state" "$amtu" "$mmtu"
done

if [[ "$MODE" == "veth" ]]; then
  echo
  log "===== 连通性 ====="
  ping -c 2 -W 2 "$SERVER_IP" | tail -2
fi

echo
log "服务端设备: $SERVER_DEV    客户端设备: $CLIENT_DEV"
log "服务端地址: $SERVER_IP    客户端地址: $CLIENT_IP"
echo
log "下一步: make test   或   ./scripts/20_run_perftest.sh --test write"
