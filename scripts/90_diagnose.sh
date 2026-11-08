#!/usr/bin/env bash
# 排障：把 "Failed to modify QP to RTR" / "Unable to Connect the HCA's through the link"
# 这类 perftest 连不上的问题，按依赖顺序逐项检查并给出修复建议。
#
# 经验：99% 的问题出在 4 项 —— (1) rxe 端口 MTU 不一致 (2) GID index 选错
#        (3) accept_local / rp_filter (4) 两端 netdev 的 MTU 与 IP 不通。
set -u

SERVER_DEV="${SERVER_DEV:-rxe0}"
CLIENT_DEV="${CLIENT_DEV:-rxe1}"
SERVER_IP="${SERVER_IP:-192.168.96.100}"
CLIENT_IP="${CLIENT_IP:-192.168.96.110}"

PASS=0; FAIL=0; WARN=0
ok()   { printf '\033[1;32m  [PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31m  [FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
wrn()  { printf '\033[1;33m  [WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# 注意：`rdma link show <dev>` 在部分 iproute2 上会报 "Wrong device name"，
# 必须从全量输出里按 "link <dev>/<port>" 匹配。
rd_netdev() {
  rdma link show 2>/dev/null | grep -E "^link $1/" | grep -o 'netdev [a-z0-9]*' | awk '{print $2}'
}

# ---------- 1. 模块与工具 ----------
sec "1. 内核模块与工具链"
if lsmod | grep -q '^rdma_rxe'; then ok "rdma_rxe 已加载"; else
  bad "rdma_rxe 未加载"; echo "         修复: modprobe rdma_rxe（WSL2 内核需 CONFIG_INFINIBAND_RXE）"
fi
for t in rdma ibv_devinfo ib_write_bw ip sysctl; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t 可用"; else bad "$t 缺失"; echo "         修复: apt-get install -y perftest rdma-core iproute2"; fi
done

# ---------- 2. RDMA 设备 ----------
sec "2. RDMA 设备状态"
for dev in "$SERVER_DEV" "$CLIENT_DEV"; do
  if [[ ! -e "/sys/class/infiniband/$dev" ]]; then
    bad "$dev 不存在"
    echo "         修复: ./scripts/10_setup_rxe.sh"
    continue
  fi
  state=$(ibv_devinfo -d "$dev" 2>/dev/null | awk -F': *' '/state:/{print $2}')
  amtu=$(ibv_devinfo -d "$dev" 2>/dev/null | awk '/active_mtu/{print $2}')
  mmtu=$(ibv_devinfo -d "$dev" 2>/dev/null | awk '/max_mtu/{print $2}')
  netdev=$(rd_netdev "$dev")
  if [[ "$state" == *ACTIVE* ]]; then ok "$dev state=$state netdev=$netdev active_mtu=$amtu max_mtu=$mmtu"
  else bad "$dev state=$state"; echo "         修复: ip link set ${netdev:-<netdev>} up（rxe 随底层 netdev 联动）"; fi
done

# ---------- 3. MTU 一致性 ----------
sec "3. MTU 一致性（最常见的坑）"
amtu_a=$(ibv_devinfo -d "$SERVER_DEV" 2>/dev/null | awk '/active_mtu/{print $2}')
amtu_b=$(ibv_devinfo -d "$CLIENT_DEV" 2>/dev/null | awk '/active_mtu/{print $2}')
if [[ -n "$amtu_a" && -n "$amtu_b" ]]; then
  if [[ "$amtu_a" == "$amtu_b" ]]; then ok "两端 rxe active_mtu 一致 ($amtu_a)"
  else bad "两端 rxe active_mtu 不一致: $amtu_a vs $amtu_b"; echo "         修复: 对两端 netdev 设相同 MTU"; fi
fi
for dev in "$SERVER_DEV" "$CLIENT_DEV"; do
  netdev=$(rd_netdev "$dev")
  [[ -n "$netdev" ]] || continue
  nmtu=$(cat "/sys/class/net/$netdev/mtu" 2>/dev/null)
  amtu=$(ibv_devinfo -d "$dev" 2>/dev/null | awk '/active_mtu/{print $2}')
  echo "    $dev: netdev($netdev) mtu=$nmtu -> rxe active_mtu=$amtu"
  if [[ "$nmtu" -lt 4600 ]] 2>/dev/null; then
    wrn "$dev 底层 netdev MTU=$nmtu，rxe 端口 MTU 会被压低（要 4096 需 netdev>=4600）"
    echo "         修复: ip link set $netdev mtu 4600"
  fi
done

# ---------- 4. GID ----------
sec "4. GID index"
for dev in "$SERVER_DEV" "$CLIENT_DEV"; do
  [[ -e "/sys/class/infiniband/$dev" ]] || continue
  idx=""
  for g in /sys/class/infiniband/"$dev"/ports/1/gids/*; do
    n=$(basename "$g"); v=$(cat "$g")
    if [[ "$v" == *:ffff:* ]]; then idx="$n"; break; fi
  done
  if [[ -n "$idx" ]]; then
    ok "$dev IPv4-mapped GID index=$idx  -> perftest 用 -x $idx"
    echo "         $(cat /sys/class/infiniband/$dev/ports/1/gids/$idx)"
  else
    bad "$dev 没有 IPv4-mapped GID（RoCEv2 未正确建立）"
  fi
done

# ---------- 5. 内核网络参数 ----------
sec "5. sysctl（accept_local / rp_filter）"
netdevs=$(for d in "$SERVER_DEV" "$CLIENT_DEV"; do rd_netdev "$d"; done | sort -u)
if [[ -z "$netdevs" ]]; then
  wrn "无法解析出 RDMA 设备绑定的 netdev，跳过本项检查"
fi
for nd in $netdevs; do
  al=$(sysctl -n "net.ipv4.conf.$nd.accept_local" 2>/dev/null)
  rp=$(sysctl -n "net.ipv4.conf.$nd.rp_filter" 2>/dev/null)
  if [[ "$al" == "1" ]]; then ok "$nd accept_local=1"; else bad "$nd accept_local=$al"; echo "         修复: sysctl -w net.ipv4.conf.$nd.accept_local=1"; fi
  if [[ "$rp" == "0" ]]; then ok "$nd rp_filter=0"; else wrn "$nd rp_filter=$rp"; echo "         修复: sysctl -w net.ipv4.conf.$nd.rp_filter=0"; fi
done

# ---------- 6. 连通性 ----------
sec "6. IP 连通性"
if ping -c 2 -W 2 "$SERVER_IP" >/dev/null 2>&1; then ok "ping $SERVER_IP 通"
else bad "ping $SERVER_IP 不通"; echo "         修复: 检查 veth 对与 IP 分配（ip -br addr）"; fi
if ip route get "$SERVER_IP" 2>/dev/null | grep -q .; then
  ok "路由存在: $(ip route get "$SERVER_IP" 2>/dev/null | head -1)"
fi

# ---------- 7. 结论 ----------
sec "结论"
printf '  PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
if [[ $FAIL -eq 0 ]]; then
  printf '\033[1;32m环境正常，可以跑 ./scripts/20_run_perftest.sh\033[0m\n'
else
  printf '\033[1;31m有 %d 项失败，按上面的“修复”提示逐条处理\033[0m\n' "$FAIL"
  exit 1
fi
