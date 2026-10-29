#!/usr/bin/env python3
"""GPU smoke test for one framework per process: torch | jax | tf."""
import sys, time


def tflops(fn, flops, iters=20):
    fn(); fn()
    t = time.perf_counter()
    for _ in range(iters):
        r = fn()
    sync(r)
    return flops * iters / (time.perf_counter() - t) / 1e12


def run_torch():
    global sync
    import torch, torchvision, torch.nn.functional as F
    import torch.distributed as dist
    sync = lambda r: torch.cuda.synchronize()
    print("torch", torch.__version__, "cuda", torch.version.cuda, "cudnn", torch.backends.cudnn.version(),
          "nccl", ".".join(map(str, torch.cuda.nccl.version())))
    assert torch.cuda.is_available(), "CUDA not available"
    print("device", torch.cuda.get_device_name(0), "cc", torch.cuda.get_device_capability(0))
    n = 8192
    a = torch.randn(n, n, device="cuda"); b = torch.randn(n, n, device="cuda")
    torch.backends.cuda.matmul.allow_tf32 = False
    print(f"matmul fp32 {tflops(lambda: a @ b, 2 * n**3):.1f} TFLOP/s")
    torch.backends.cuda.matmul.allow_tf32 = True
    print(f"matmul tf32 {tflops(lambda: a @ b, 2 * n**3):.1f} TFLOP/s")
    ah, bh = a.half(), b.half()
    print(f"matmul fp16 {tflops(lambda: ah @ bh, 2 * n**3):.1f} TFLOP/s")
    ab, bb = a.bfloat16(), b.bfloat16()
    print(f"matmul bf16 {tflops(lambda: ab @ bb, 2 * n**3):.1f} TFLOP/s")
    del a, b, ah, bh, ab, bb

    # cuDNN convolution, checked against the CPU
    torch.backends.cudnn.allow_tf32 = False
    x = torch.randn(8, 64, 56, 56); w = torch.randn(128, 64, 3, 3)
    err = (F.conv2d(x.cuda(), w.cuda(), padding=1).cpu() - F.conv2d(x, w, padding=1)).abs().max().item()
    print(f"conv2d GPU vs CPU max abs diff {err:.2e}")
    assert err < 1e-2, "conv2d mismatch"

    # ResNet-18 training steps, mixed precision
    torch.backends.cudnn.benchmark = True
    m = torchvision.models.resnet18(num_classes=10).cuda().to(memory_format=torch.channels_last)
    opt = torch.optim.SGD(m.parameters(), lr=0.01)
    xb = torch.randn(64, 3, 224, 224, device="cuda").to(memory_format=torch.channels_last)
    yb = torch.randint(0, 10, (64,), device="cuda")

    def step():
        with torch.autocast("cuda", dtype=torch.bfloat16):
            loss = F.cross_entropy(m(xb), yb)
        opt.zero_grad(); loss.backward(); opt.step()
        return loss
    for _ in range(5): step()
    torch.cuda.synchronize(); t = time.perf_counter()
    for _ in range(30): loss = step()
    torch.cuda.synchronize()
    print(f"resnet18 train bf16 {30 * 64 / (time.perf_counter() - t):.0f} img/s, loss {loss.item():.3f}")

    # torch.compile (Triton kernels)
    f = torch.compile(lambda t: torch.nn.functional.gelu(t) * t.sin())
    t = torch.randn(1 << 20, device="cuda")
    err = (f(t) - torch.nn.functional.gelu(t) * t.sin()).abs().max().item()
    print(f"torch.compile ok, max abs diff {err:.2e}")

    # NCCL, single rank
    import os, tempfile
    store = tempfile.mktemp()
    dist.init_process_group("nccl", init_method=f"file://{store}", rank=0, world_size=1)
    v = torch.ones(1 << 20, device="cuda"); dist.all_reduce(v)
    print("nccl all_reduce ok", v[0].item())
    dist.destroy_process_group()

    # Safe loading default
    import io
    buf = io.BytesIO(); torch.save({"w": torch.ones(2)}, buf); buf.seek(0)
    import inspect
    print("torch.load weights_only default:", inspect.signature(torch.load).parameters["weights_only"].default,
          "(None means True since 2.6)")
    print("peak GPU memory", f"{torch.cuda.max_memory_allocated() / 2**30:.1f} GiB")


def run_jax():
    global sync
    import jax, jax.numpy as jnp
    sync = lambda r: r.block_until_ready()
    print("jax", jax.__version__, "devices", jax.devices())
    assert jax.devices()[0].platform == "gpu", "JAX is not on the GPU"
    n = 8192
    k = jax.random.PRNGKey(0)
    a = jax.random.normal(k, (n, n), jnp.bfloat16); b = jax.random.normal(k, (n, n), jnp.bfloat16)
    mm = jax.jit(lambda a, b: a @ b)
    print(f"matmul bf16 {tflops(lambda: mm(a, b), 2 * n**3):.1f} TFLOP/s")
    x = jax.random.normal(k, (8, 64, 56, 56)); w = jax.random.normal(k, (128, 64, 3, 3))
    conv = jax.jit(lambda x, w: jax.lax.conv(x, w, (1, 1), "SAME"))
    y = conv(x, w); sync(y)
    g = jax.jit(jax.grad(lambda w: conv(x, w).sum()))(w); sync(g)
    print("conv + grad ok", y.shape, g.shape)


def run_tf():
    global sync
    import tensorflow as tf
    sync = lambda r: r.numpy()
    gpus = tf.config.list_physical_devices("GPU")
    print("tensorflow", tf.__version__, "gpus", gpus)
    assert gpus, "TensorFlow sees no GPU"
    for g in gpus: tf.config.experimental.set_memory_growth(g, True)
    n = 8192
    a = tf.random.normal((n, n)); b = tf.random.normal((n, n))
    mm = tf.function(lambda a, b: tf.matmul(a, b))
    print(f"matmul fp32/tf32 {tflops(lambda: mm(a, b), 2 * n**3):.1f} TFLOP/s")
    x = tf.random.normal((8, 56, 56, 64)); w = tf.random.normal((3, 3, 64, 128))
    with tf.device("/CPU:0"):
        ref = tf.nn.conv2d(x, w, 1, "SAME")
    tf.config.experimental.enable_tensor_float_32_execution(False)
    err = tf.reduce_max(tf.abs(tf.nn.conv2d(x, w, 1, "SAME") - ref)).numpy()
    print(f"conv2d GPU vs CPU max abs diff {err:.2e}")
    import keras
    model = keras.Sequential([keras.Input((32, 32, 3)), keras.layers.Conv2D(32, 3, activation="relu"),
                              keras.layers.GlobalAveragePooling2D(), keras.layers.Dense(10)])
    model.compile("adam", keras.losses.SparseCategoricalCrossentropy(from_logits=True))
    h = model.fit(tf.random.normal((512, 32, 32, 3)), tf.random.uniform((512,), 0, 10, tf.int32),
                  epochs=2, verbose=0)
    print("keras fit ok, loss", round(h.history["loss"][-1], 3))


{"torch": run_torch, "jax": run_jax, "tf": run_tf}[sys.argv[1]]()
print("PASS", sys.argv[1])
