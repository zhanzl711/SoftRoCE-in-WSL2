# soft-roce-lab

在 **WSL2 / Linux** 上用 Soft-RoCE（`rxe`）搭一个**可复现**的 RDMA 测试床：一条命令建环境，一条命令自检，一条命令出带宽数据。

为什么做这个：RDMA 调优的绝大多数弯路，都来自「没有可复现的测试床，只能在生产环境上试错」。这个仓库把环境搭建、MTU/GID 等隐性坑固化成脚本，让别人省掉你踩过的那几天。

附带一个与存储相关的小工具：`tools/ec_amplification.py` —— 估算「对象存储自带 EC」对 block 分块文件系统的读放大。

---

## 快速开始

### WSL2（Ubuntu）

```powershell
# PowerShell 里进 WSL 并以 root 执行（避免 sudo 交互）
wsl -u root -- bash -c "cd /mnt/c/path/to/soft-roce-lab && make setup && make diag && make test"
```

### 普通 Linux（root）

```bash
make install     # 装 perftest / rdma-core / iproute2 / ethtool
make setup       # 建 veth 对 + rxe0/rxe1
make diag        # 自检
make test        # 跑 write / read / send
make clean       # 清理
```

---

## 本仓库实测基线

环境：WSL2 / `6.6.123.2-microsoft-standard-WSL2+`，x86_64，veth 虚拟网卡，rxe 软件实现。

| 项目 | 结果 |
|---|---|
| rxe 端口 MTU | **4096**（底层 netdev MTU 设为 4600） |
| GID index | **1**（IPv4-mapped GID） |
| `ib_write_bw` | **5.19 Gb/s** avg（peak 5.40），msg size 64KiB |
| `ib_read_bw` | **1.82 Gb/s** avg（peak 2.38），msg size 64KiB |

> 这组数字是 **软件回环路径** 的结果，不代表真实网卡性能。真实硬件请用两块物理网卡 + `rxe`/Mellanox 驱动重测。
> 复现命令见 `docs/RESULTS.md`。

---

## 核心机制：rxe 端口 MTU 由底层 netdev 推导

这是本仓库最有价值的一条实测结论：**rxe 没有独立的端口 MTU 设置项，端口 MTU 是从底层 netdev 的 MTU 推导出来的。**

实测映射（`ibv_devinfo` 的 `active_mtu`）：

| 底层 netdev MTU | rxe `active_mtu` |
|---|---|
| 1500（默认） | 1024 |
| 4138 | 2048 |
| 4150 | 2048 |
| **4600** | **4096** |

**结论：想拿到 4096 的 RDU MTU，底层 netdev 的 MTU 必须 ≥ 4600。**

这解释了一个非常常见的现象：明明 `max_mtu` 显示 4096，实际 perftest 协商出来的 `Mtu` 却只有 1024 或 2048 —— 不是 RDMA 栈的问题，是网卡 MTU 没给够。

推导逻辑在 rxe 驱动里：端口 MTU ≈ `netdev_mtu - 54`（以太网头 14 + IPv6 头 40），再向下取不超过 `max_mtu` 的 2 的幂。

---

## GID index：连不上时第一个要查的

Soft-RoCE 在 RoCEv2 下，`/sys/class/infiniband/<dev>/ports/1/gids/` 里：

```
gid[0] = fe80:0000:0000:0000:6410:5fff:fe8c:993c   # RoCEv2 link-local
gid[1] = 0000:0000:0000:0000:0000:ffff:c0a8:6064   # IPv4-mapped 192.168.96.100
gid[2..] = 0000:...:0000                             # 空闲
```

要在 IP 网络上跑，必须用 **IPv4-mapped 那个 GID 的 index**，也就是 `-x 1`。用错 index 的典型症状就是：

```
Failed to modify QP 17 to RTR
Unable to Connect the HCA's through the link
```

`scripts/20_run_perftest.sh` 会自动探测这个 index。

---

## 目录结构

```
soft-roce-lab/
├── Makefile                    # 入口：install / setup / diag / test / clean
├── scripts/
│   ├── 00_install.sh           # 依赖安装
│   ├── 10_setup_rxe.sh         # 建 veth 对 + rxe 端口（幂等）
│   ├── 20_run_perftest.sh      # 跑 perftest（自动选 GID index）
│   └── 90_diagnose.sh          # 排障：把 QP 建不起来的四个原因逐条查
├── tools/
│   └── ec_amplification.py     # 对象存储 EC 读放大估算器
└── docs/
    ├── TROUBLESHOOTING.md      # 故障手册
    └── RESULTS.md              # 实测结果存档（贴你的机器数据）
```

---

## 排障速查

```bash
make diag
```

逐项检查：模块是否加载 → 端口是否 ACTIVE → **两端 MTU 是否一致** → **GID index 是否正确** → `accept_local`/`rp_filter` → IP 连通性。

详细的故障原因与修复见 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)。

---

## 边界：这个测试床不能做什么

| 场景 | 能不能用 | 说明 |
|---|---|---|
| 验证 RDMA 协议栈、QP 建立、perftest 跑通 | ✅ | 本仓库的主要用途 |
| 验证自己代码里的 RDMA 逻辑（verbs API） | ✅ | 编译 `-libverbs` 就能用 |
| 测真实网卡带宽 / 延迟 | ❌ | veth + rxe 是纯软件路径，没有硬件计时 |
| DPDK / SPDK 性能测试 | ⚠️ | SPDK 官方不支持 WSL2；建议用裸机或 VM |
| 验证内核模块 / 真实中断路径 | ❌ | WSL2 内核不支持加载第三方内核模块 |

要测硬件路径：两台裸机 + 物理网卡；或用 DPDK 的 `vfio-pci` + 巨页在 KVM guest 里跑。

---

## 对象存储 EC 的读放大（附带工具）

JuiceFS 这类 block 分块文件系统，每个 block 写成一个独立 object：

```
chunks/<id/1e6>/<id/1000>/<id>_<blockIdx>_<blockSize>
```

所以当对象存储侧开启 EC(k+m) 时，**EC 的编码单元就是 block**。随机小读会同时踩两个放大：

```bash
python3 tools/ec_amplification.py --block-size 4MiB --ec-k 4 --ec-m 2 --read-size 4KiB
```

```
【正常态】拉取 3 个分片
  实际传输    2.00 MiB
  相对有效数据 512.00x
【降级态】拉取 4 个分片
  实际传输    2.67 MiB
  相对有效数据 682.67x
  相对正常态  1.33x 尖刺
```

放大来自两件事叠加：**必须取回整块** + **必须凑够 m+1 个分片**。降级时尖刺再放大 k/(m+1)。

---

## License

MIT，见 [LICENSE](LICENSE)。
