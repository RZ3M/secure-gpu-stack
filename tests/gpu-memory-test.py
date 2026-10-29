#!/usr/bin/env python3
"""Does GPU memory leak from one process to the next?

    python3 tests/gpu-memory-test.py write   # as one user: fill GPU memory with a marker, exit
    python3 tests/gpu-memory-test.py read    # as another user (in video): read fresh memory

Both take 90% of the GPU's free memory (or a size in MB as a second
argument), so the reader has to get the writer's old pages: a small read
could land on pages nobody used, and show zeros either way. The read copies
the fresh allocation back in 256 MB pieces before writing anything. "marker
found 0 times; non-zero bytes 0" means the driver cleared it. On krabs (GTX
1070, driver 580.178.04) it did, across users. Run it on Lambda's data-center
GPUs too, with and without MIG. Uses the CUDA driver API through ctypes;
nothing else to install.
"""
import ctypes, sys

mode = sys.argv[1]
cu = ctypes.CDLL("libcuda.so.1")


def ok(r, what):
    if r != 0:
        sys.exit(f"{what} failed: {r}")


ok(cu.cuInit(0), "cuInit")
dev = ctypes.c_int(); ok(cu.cuDeviceGet(ctypes.byref(dev), 0), "cuDeviceGet")
ctx = ctypes.c_void_p(); ok(cu.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev), "cuCtxCreate")
free, total = ctypes.c_size_t(), ctypes.c_size_t()
ok(cu.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total)), "cuMemGetInfo")
chunk = 256 << 20
n = (int(sys.argv[2]) << 20) if len(sys.argv) > 2 else (free.value * 9 // 10) // chunk * chunk
ptr = ctypes.c_uint64(); ok(cu.cuMemAlloc_v2(ctypes.byref(ptr), ctypes.c_size_t(n)), "cuMemAlloc")
marker = b"SGS-SECRET-" * 8
if mode == "write":
    piece = (marker * (chunk // len(marker) + 1))[:chunk]
    for off in range(0, n, chunk):
        ok(cu.cuMemcpyHtoD_v2(ctypes.c_uint64(ptr.value + off), piece, ctypes.c_size_t(min(chunk, n - off))), "cuMemcpyHtoD")
    cu.cuCtxSynchronize()
    print(f"wrote {n >> 20} MB of marker ({total.value >> 20} MB GPU)")
else:
    host = ctypes.create_string_buffer(chunk)
    hits = nonzero = 0
    for off in range(0, n, chunk):
        size = min(chunk, n - off)
        ok(cu.cuMemcpyDtoH_v2(host, ctypes.c_uint64(ptr.value + off), ctypes.c_size_t(size)), "cuMemcpyDtoH")
        data = host.raw[:size]
        hits += data.count(b"SGS-SECRET-")
        nonzero += size - data.count(0)
    print(f"read {n >> 20} MB fresh: marker found {hits} times; non-zero bytes {nonzero}")
