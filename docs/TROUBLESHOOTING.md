# 故障手册：perftest 连不上的四个真实原因

按「出现频率 × 排查难度」排序。每一条都对应 `scripts/90_diagnose.sh` 里的检查项。

---

## 症状 1：`Failed to modify QP to RTR` / `Unable to Connect the HCA's through the link`

这是 Soft-RoCE 最常见的一个报错，**四成是 MTU，三成是 GID index，其余是内核网络参数**。

QP 状态机卡在 RTR（Ready To Receive），说明 QP 的路径信息（AH/ATH）没交换成功 —— 通常是底层链路层参数不匹配或 GID 选错。

### 原因 A：MTU 不一致（最常见）

**现象**：perftest 输出的 `Mtu` 是 1024 或 2048，而你以为它是 4096。

**根因**：rxe 的端口 MTU 不是独立设置项，而是从底层 netdev 推导的：

```
port_mtu ≈ floor_pow2(netdev_mtu - 54)，且不超过 max_mtu(4096)
```

实测：

| netdev MTU | rxe active_mtu |
|---|---|
| 1500（默认） | 1024 |
| 4138 | 2048 |
| 4150 | 2048 |
| 4600 | 4096 |

**修复**：

```bash
ip link set veth0 mtu 4600
ip link set veth1 mtu 4600
# 注意：改 netdev 的 MTU 后 rxe 会自动跟随，不需要（也不能）单独设 rxe 的 MTU
```

**验证**：

```bash
ibv_devinfo -d rxe0 | grep -E 'active_mtu|max_mtu'
# 期望: active_mtu: 4096 (5)
```

> 反面教材：曾经把 netdev MTU 设成 4096，结果 rxe 端口只有 2048，白排查半小时。
> **netdev MTU 要给得比你想的 RDMA MTU 更大**，4600 是最省事的值。

### 原因 B：GID index 选错

**现象**：同上错误码，但 MTU 确认无误。

**根因**：Soft-RoCE 的 GID 表里，index 0 是 link-local 的 RoCEv2 GID，**IPv4-mapped 的那个在别的 index**（本机实测是 1）。用错 index，QP 交换到的 GID 对不上。

**查看**：

```bash
for g in /sys/class/infiniband/rxe0/ports/1/gids/*; do
  echo "$(basename $g) = $(cat $g)"
done
```

```
0 = fe80:0000:0000:0000:6410:5fff:fe8c:993c   # link-local
1 = 0000:0000:0000:0000:0000:ffff:c0a8:6064   # IPv4-mapped 192.168.96.100  <-- 用这个
```

**修复**：perftest 加 `-x 1`。

```bash
ib_write_bw -d rxe0 -x 1 192.168.96.100
```

`scripts/20_run_perftest.sh` 会自动探测，一般不用手写。

### 原因 C：accept_local / rp_filter

**现象**：MTU、GID 都对，还是连不上；或者 `ping` 通但 RDMA 不通。

**根因**：veth 两端在同一个子网、同一台机器上，回环路径上源地址与本机地址相同，`accept_local=0` 时内核会丢掉这种包；`rp_filter=2`（默认严格反向路径检查）也会把回环流量丢掉。

**修复**：

```bash
sysctl -w net.ipv4.conf.veth0.accept_local=1
sysctl -w net.ipv4.conf.veth1.accept_local=1
sysctl -w net.ipv4.conf.veth0.rp_filter=0
sysctl -w net.ipv4.conf.veth1.rp_filter=0
```

### 原因 D：rxe 设备没绑到底层网卡 / 端口没起来

```bash
rdma link show
# 期望形如: link rxe0/1 state ACTIVE physical_state LINK_UP netdev veth0
```

`state` 不是 ACTIVE 时，先确认底层 netdev 是 up 的（rxe 随 netdev 联动）：

```bash
ip link set veth0 up
```

---

## 症状 2：`rdma link add` 报找不到命令 / 设备不存在

```bash
apt-get install -y rdma-core iproute2   # Debian/Ubuntu
dnf install -y rdma-core iproute        # RHEL/Fedora
```

`rdma link` 只支持 `show` / `add` / `delete`，**没有 `set mtu`**——这正是 MTU 必须在 netdev 上设的原因。

---

## 症状 3：WSL2 里 `modprobe rdma_rxe` 失败

WSL2 用的是微软自带的内核（`6.6.x-microsoft-standard-WSL2+`），它**不带 `CONFIG_INFINIBAND_RXE`**，所以装不了 rxe 模块。

**症状**：

```
modprobe: FATAL: Module rdma_rxe not found in directory /lib/modules/...
```

**解法**：自己编译 WSL2 内核（微软的 `MicrosoftWSL` 仓库有现成流程），加上：

```
CONFIG_INFINIBAND=y
CONFIG_INFINIBAND_RXE=y
```

编译时注意：

```bash
# 用 Microsoft 的内核配置做基底，不要用上游 config
cp /mnt/c/WSL2-Linux-Kernel/MicrosoftWSL/.wslconfig ...
# 或者
make KCONFIG_ALLCONFIG=Microsoft.config allnoconfig
make -j$(nproc)
```

> 本仓库在**已有 rxe 的环境**上验证（原生 Linux 或自编译 WSL 内核）。
> 未自编译内核的读者可以先看 `docs/RESULTS.md` 里的原理部分，
> 读懂「MTU 从哪来」比跑通环境更有价值。

---

## 症状 4：`ib_write_bw` 跑起来了但带宽低得离谱

先分清是**环境问题**还是**环境天花板**：

| 现象 | 判断 |
|---|---|
| `write` 明显快于 `read` | 正常（RDMA READ 走的是 RDMA 网络，WRITE 走存储路径） |
| 两者都只有几 Gb/s | 正常，这是 veth + 软件 rxe 的上限 |
| 只有 0.x Gb/s | 检查 `--depth`、`--size`，以及 CPU 是否被打满 |

**软件路径的经验值**（本机实测）：write ≈ 5.2 Gb/s，read ≈ 1.8 Gb/s。

不要用这个数字去对标真实网卡 —— 这里的瓶颈是 CPU 上的软件加密/拷贝，不是链路。

---

## 症状 5：perftest 报 `ibv_rc_rdma_bw: command not found`

`ibv_rc_rdma_bw` 不在 perftest 的默认安装里（有的发行版拆包了）：

```bash
apt-get install -y perftest   # 应包含 ibv_rc_rdma_bw
# 若确实没有：
apt-get install -y libibverbs-utils
```

或直接用 `ib_write_bw --report_gbits` + `-M` 参数近似。

---

## 一键自检

```bash
./scripts/90_diagnose.sh
```

输出形如：

```
== 3. MTU 一致性（最常见的坑） ==
  rxe0: netdev(veth0) mtu=4600 -> rxe active_mtu=4096
  rxe1: netdev(veth1) mtu=4600 -> rxe active_mtu=4096
```
