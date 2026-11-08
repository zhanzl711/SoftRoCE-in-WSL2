# soft-roce-lab
#
# 在 WSL2 / Linux 上用 Soft-RoCE (rxe) 搭一个可复现的 RDMA 测试床。
# 所有目标都以 root 身份执行（需要创建 veth / rdma link）。

SHELL := /bin/bash
SCRIPTS := scripts

.PHONY: help install setup setup-single test test-write test-read diag clean ec

help:            ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install:         ## 安装依赖 (perftest / rdma-core / iproute2 / ethtool)
	@bash $(SCRIPTS)/00_install.sh

setup:           ## 建立 veth 对 + 两个 rxe 端口 (rxe0/rxe1)
	@bash $(SCRIPTS)/10_setup_rxe.sh --mode veth

setup-single:    ## 只建一个 rxe 端口，绑到现有网卡
	@bash $(SCRIPTS)/10_setup_rxe.sh --mode single --netdev-a eth0

diag:            ## 自检：模块 / 端口状态 / MTU / GID / sysctl / 连通性
	@bash $(SCRIPTS)/90_diagnose.sh

test:            ## 跑 write + read + send 三项测试
	@bash $(SCRIPTS)/20_run_perftest.sh --test all

test-write:      ## 只跑 RDMA WRITE 带宽
	@bash $(SCRIPTS)/20_run_perftest.sh --test write

test-read:       ## 只跑 RDMA READ 带宽
	@bash $(SCRIPTS)/20_run_perftest.sh --test read

ec:              ## 对象存储 EC 读放大估算（默认 4MiB block, 4+2, 4KiB 随机读）
	@python3 tools/ec_amplification.py

clean:           ## 删除 rxe 设备与 veth 对
	@bash $(SCRIPTS)/10_setup_rxe.sh --teardown
