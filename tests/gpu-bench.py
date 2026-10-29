#!/usr/bin/env python3
"""Training speed on one GPU, for comparing two installs on the same hardware.

    python3 tests/gpu-bench.py [STEPS]

ResNet-50 (images/s) and a small GPT-style transformer (tokens/s), both
trained with bf16 autocast, plus a bf16 matmul. PyTorch and torchvision only,
random data, nothing downloaded, no torch.compile (so different PyTorch
versions run the same code). Prints the results and one JSON line. Run it with
nothing else on the GPU; take the median of a few runs.
"""
import json, sys, time
import torch, torch.nn as nn, torch.nn.functional as F, torchvision

steps = int(sys.argv[1]) if len(sys.argv) > 1 else 100
assert torch.cuda.is_available(), "CUDA not available"
dev = "cuda"
torch.backends.cudnn.benchmark = True
res = {"torch": torch.__version__, "cuda": torch.version.cuda, "cudnn": torch.backends.cudnn.version(),
       "gpu": torch.cuda.get_device_name(0)}


def timed(step, n):
    for _ in range(10):
        step()
    torch.cuda.synchronize()
    t = time.perf_counter()
    for _ in range(n):
        step()
    torch.cuda.synchronize()
    return (time.perf_counter() - t) / n


n = 8192
a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
res["matmul_bf16_tflops"] = round(2 * n**3 / timed(lambda: a @ b, 50) / 1e12, 1)
del a, b

model = torchvision.models.resnet50().to(dev, memory_format=torch.channels_last)
opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
x = torch.randn(64, 3, 224, 224, device=dev).to(memory_format=torch.channels_last)
y = torch.randint(0, 1000, (64,), device=dev)


def resnet_step():
    with torch.autocast(dev, dtype=torch.bfloat16):
        loss = F.cross_entropy(model(x), y)
    opt.zero_grad(set_to_none=True)
    loss.backward()
    opt.step()


res["resnet50_img_per_s"] = round(64 / timed(resnet_step, steps))
del model, opt, x, y
torch.cuda.empty_cache()


class GPT(nn.Module):
    def __init__(self, vocab=32000, d=768, layers=8, heads=12, ctx=1024):
        super().__init__()
        self.tok, self.pos = nn.Embedding(vocab, d), nn.Embedding(ctx, d)
        layer = nn.TransformerEncoderLayer(d, heads, 4 * d, dropout=0.0, activation="gelu",
                                           batch_first=True, norm_first=True)
        self.blocks = nn.TransformerEncoder(layer, layers)
        self.head = nn.Linear(d, vocab, bias=False)
        self.register_buffer("mask", nn.Transformer.generate_square_subsequent_mask(ctx), persistent=False)

    def forward(self, t):
        h = self.tok(t) + self.pos(torch.arange(t.shape[1], device=t.device))
        return self.head(self.blocks(h, mask=self.mask[: t.shape[1], : t.shape[1]], is_causal=True))


batch, ctx = 8, 1024
gpt = GPT(ctx=ctx).to(dev)
opt = torch.optim.AdamW(gpt.parameters(), lr=3e-4)
tokens = torch.randint(0, 32000, (batch, ctx + 1), device=dev)


def gpt_step():
    with torch.autocast(dev, dtype=torch.bfloat16):
        logits = gpt(tokens[:, :-1])
        loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]), tokens[:, 1:].reshape(-1))
    opt.zero_grad(set_to_none=True)
    loss.backward()
    opt.step()


res["gpt_tokens_per_s"] = round(batch * ctx / timed(gpt_step, steps))
res["peak_gpu_mem_gib"] = round(torch.cuda.max_memory_allocated() / 2**30, 1)
for k, v in res.items():
    print(f"{k:22} {v}")
print(json.dumps(res))
