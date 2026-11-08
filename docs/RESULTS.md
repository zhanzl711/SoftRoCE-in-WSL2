# 实测结果存档

把每次测量的环境与数据贴到这里，形成可追溯的基线。
**每组数据必须同时记录：内核版本、底层 netdev MTU、rxe active_mtu、GID index、消息大小、队列深度。**
没有这些上下文的数字没有意义。

---

## 基线 1：WSL2 软件回环（2026-11-08）

### 环境

| 项 | 值 |
|---|---|
| 内核 | `Linux MS-BUXETYLUKYXH 6.6.123.2-microsoft-standard-WSL2+ #1 SMP PREPREC_DYNAMIC` |
| 架构 | x86_64 |
| 传输 | Soft-RoCE (`rdma_rxe`)，veth 虚拟网卡 |
| 底层 netdev MTU | 4600 |
| rxe `active_mtu` | **4096** |
| `max_mtu` | 4096 |
| GID index | 1（IPv4-mapped） |
| 链路类型 | Ethernet |
| 消息大小 | 65536 (64KiB) |
| 队列深度 | 128 (默认) |

### 结果

```
# ib_write_bw (server: rxe0, client: rxe1)
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 65536      5000             5.40               5.19              0.009898

# ib_read_bw
 #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
 65536      1000             2.38               1.82              0.003466
```

### 复现命令

```bash
./scripts/10_setup_rxe.sh --mode veth --mtu 4600
./scripts/20_run_perftest.sh --test write
./scripts/20_run_perftest.sh --test read
```

### MTU 映射实测

| netdev MTU | rxe active_mtu |
|---|---|
| 1500 | 1024 |
| 4138 | 2048 |
| 4150 | 2048 |
| 4600 | 4096 |

> 推导：端口 MTU ≈ `floor_pow2(netdev_mtu - 54)`，上限 `max_mtu`。
> 想要 4096，底层 netdev 至少要 4600。

---

## 基线 2：真实硬件（待填）

在两台裸机 + 物理网卡上重测，替换上面的软件路径数字。

| 项 | 值 |
|---|---|
| 内核 | |
| 网卡型号 | |
| 驱动 | |
| MTU | |
| GID index | |
| 消息大小 / 深度 | |
| write / read 带宽 | |
| 备注 | |

---

## 基线 3：裸机 DPDK/SPDK（待填）

SPDK 官方不支持 WSL2，请在裸机或 KVM guest（vfio-pci + 巨页）中测量。

| 项 | 值 |
|---|---|
| 平台 | |
| NIC | |
| 队列数 / 队列大小 | |
| MTU | |
| IOPS / 带宽 | |
| 备注 | |

---

## 填写模板

```markdown
## 基线 N：<场景>（YYYY-MM-DD）

### 环境
| 项 | 值 |
|---|---|
| 内核 | |
| 网卡/传输 | |
| MTU | |
| GID index | |
| 消息大小 / 队列深度 | |

### 结果
```
<perftest 输出>
```

### 结论
<一句话：瓶颈在哪、跟上一组比变化多少>
```
