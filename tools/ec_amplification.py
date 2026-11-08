#!/usr/bin/env python3
# 估算「对象存储自带 EC」时，JuiceFS 这类 block 分块文件系统的读放大与降级读代价。
#
# 背景：JuiceFS 把每个 block 写成一个独立的 object
#   key: chunks/<id/1e6>/<id/1000>/<id>_<blockIdx>_<blockSize>
#   源码: pkg/chunk/cached_store.go -> rSlice.key()
# 因此当对象存储侧开启 EC(k+m) 后，**EC 的编码单元就是 JuiceFS 的 block**。
#
# 用法:
#   python3 tools/ec_amplification.py --block-size 4MiB --ec-k 4 --ec-m 2 --read-size 4KiB
#   python3 tools/ec_amplification.py --ec-k 10 --ec-m 4 --read-size 64KiB --mode seq
#   python3 tools/ec_amplification.py --json
import argparse
import json
import sys

try:  # 让 Windows 控制台也能正确输出中文
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

UNITS = {"B": 1, "KB": 1024, "KIB": 1024, "MB": 1024**2, "MIB": 1024**2,
         "GB": 1024**3, "GIB": 1024**3, "TB": 1024**4, "TIB": 1024**4}


def parse_size(s: str) -> int:
    s = s.strip()
    for suffix in sorted(UNITS, key=len, reverse=True):
        if s.upper().endswith(suffix):
            return int(float(s[: -len(suffix)].strip()) * UNITS[suffix])
    return int(float(s))


def human(n: float) -> str:
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{int(n)} B" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} TiB"


def analyze(block_size: int, k: int, m: int, read_size: int, mode: str) -> dict:
    if k <= 0 or m < 0:
        raise ValueError("k 必须 > 0，m 必须 >= 0")
    if read_size <= 0:
        raise ValueError("read-size 必须 > 0")

    total_shards = k + m
    shard_bytes = block_size / total_shards

    if mode == "rand":
        # 随机小读：只命中 1 个 block，但该 block 必须整块取回；
        # 解出其中 1 个数据分片需要任意 m+1 个分片。
        useful = read_size
        shards_normal = min(m + 1, k + m)
        shards_degraded = k          # 少了一个数据分片 -> 只能读满 k 个数据分片
        desc = "随机读（每次只命中一个块）"
    else:
        # 顺序读满一个块：需要全部 k 个数据分片；
        # 降级时必须读全 k+m 个分片才能重建并校验。
        useful = block_size
        shards_normal = k
        shards_degraded = total_shards
        desc = "顺序读（读满整块）"

    transfer_normal = shard_bytes * shards_normal
    transfer_degraded = shard_bytes * shards_degraded

    return {
        "block_size": block_size,
        "ec": f"{k}+{m}",
        "read_size": read_size,
        "mode": mode,
        "mode_desc": desc,
        "total_shards": total_shards,
        "shard_bytes": shard_bytes,
        "shards_fetched_normal": shards_normal,
        "shards_fetched_degraded": shards_degraded,
        "transfer_normal": transfer_normal,
        "transfer_degraded": transfer_degraded,
        "useful_bytes": useful,
        "read_amplification_normal": transfer_normal / useful,
        "read_amplification_degraded": transfer_degraded / useful,
        "storage_overhead": total_shards / k,
        "repair_traffic_per_lost_shard": k * shard_bytes,
        "repair_traffic_ratio": k * shard_bytes / block_size,
    }


def fmt_amp(x: float) -> str:
    return f"{x:.2f}x" + ("（<=1：不放大，只传数据分片）" if x <= 1.0 else "")


def main() -> int:
    p = argparse.ArgumentParser(
        description="对象存储 EC(k+m) 对 block 分块文件系统的读放大估算",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--block-size", default="4MiB", help="块大小，JuiceFS 默认 4MiB")
    p.add_argument("--ec-k", type=int, default=4, help="数据分片数 k")
    p.add_argument("--ec-m", type=int, default=2, help="校验分片数 m")
    p.add_argument("--read-size", default="4KiB", help="单次有效读大小（随机读场景）")
    p.add_argument("--mode", choices=["rand", "seq"], default="rand",
                   help="rand=每次只读一点（默认）；seq=顺序读满整块")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    args = p.parse_args()

    try:
        r = analyze(parse_size(args.block_size), args.ec_k, args.ec_m,
                    parse_size(args.read_size), args.mode)
    except ValueError as e:
        print(f"错误: {e}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0

    print(f"""
对象存储 EC 读放大估算
============================================================
  块大小        {human(r['block_size'])}      （= EC 的编码单元）
  EC 方案       {r['ec']}                      （共 {r['total_shards']} 个分片）
  单分片大小    {human(r['shard_bytes'])}
  读模式        {r['mode_desc']}
  有效数据量    {human(r['useful_bytes'])}

【正常态】拉取 {r['shards_fetched_normal']} 个分片
  实际传输    {human(r['transfer_normal'])}
  相对有效数据 {fmt_amp(r['read_amplification_normal'])}

【降级态】拉取 {r['shards_fetched_degraded']} 个分片（少分片就要多读）
  实际传输    {human(r['transfer_degraded'])}
  相对有效数据 {fmt_amp(r['read_amplification_degraded'])}
  相对正常态  {r['read_amplification_degraded'] / max(r['read_amplification_normal'], 1e-9):.2f}x 尖刺

【存储开销】 {r['storage_overhead']:.2f}x  ((k+m)/k)
【修复代价】 单分片丢失需读 {human(r['repair_traffic_per_lost_shard'])}，
             相当于 {r['repair_traffic_ratio']:.2f} 个块的流量
============================================================
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
