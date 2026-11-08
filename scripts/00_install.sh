#!/usr/bin/env bash
# 安装 Soft-RoCE 测试床所需的依赖。
set -euo pipefail

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root"

PKGS_COMMON="perftest rdma-core iproute2 ethtool"

if command -v apt-get >/dev/null 2>&1; then
  log "检测到 Debian/Ubuntu，安装: $PKGS_COMMON"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends $PKGS_COMMON
elif command -v dnf >/dev/null 2>&1; then
  log "检测到 RHEL/Fedora，安装: $PKGS_COMMON"
  dnf install -y perftest rdma-core iproute ethtool
elif command -v yum >/dev/null 2>&1; then
  log "检测到 CentOS，安装: $PKGS_COMMON"
  yum install -y perftest librdmacm-utils rdma-core iproute ethtool
else
  die "不支持的包管理器，请手动安装: $PKGS_COMMON"
fi

log "校验"
for t in rdma ibv_devinfo ib_write_bw ip; do
  command -v "$t" >/dev/null 2>&1 && log "  $t -> $(command -v $t)" || die "  $t 安装后仍缺失"
done

if lsmod | grep -q '^rdma_rxe'; then
  log "  rdma_rxe 模块已加载"
else
  log "  尝试加载 rdma_rxe ..."
  modprobe rdma_rxe 2>/dev/null && log "  已加载" || log "  加载失败：当前内核未提供 CONFIG_INFINIBAND_RXE"
fi

cat <<'EOF'

下一步:
  ./scripts/10_setup_rxe.sh      # 建 veth 对 + 两个 rxe 端口
  ./scripts/90_diagnose.sh       # 自检
  ./scripts/20_run_perftest.sh   # 跑带宽测试
EOF
