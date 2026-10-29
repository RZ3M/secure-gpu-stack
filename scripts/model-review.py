#!/usr/bin/env python3
"""Ask open-weight models (through OpenRouter) to red-team the stack's code.

    scripts/model-review.py [--model M ...] [--focus TEXT] [--out DIR] FILE...

The models only read: they get the files as text and return findings. They
have no tools and run nothing, so their answers are untrusted suggestions to
verify on a test machine, never commands to execute. Only the files named on
the command line are sent; never send secrets or machine details.

The API key comes from OPENROUTER_API_KEY, or from the repository's .env
(OPENROUTER_API_KEY=...), which is gitignored. It's never printed.
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_MODELS = ["deepseek/deepseek-v4.1-flash-1017", "z-ai/glm-5.3-flash"]
API = "https://openrouter.ai/api/v1/chat/completions"

SYSTEM = """You are a senior Linux and GPU-infrastructure security engineer red-teaming
"Secure GPU Stack": a one-command installer that turns an Ubuntu 24.04 GPU
machine into an ML workstation like Lambda Stack (NVIDIA driver, CUDA, cuDNN,
NCCL, PyTorch, TensorFlow, JAX, JupyterLab, Docker with the NVIDIA Container
Toolkit), with secure defaults, plus a posture-audit command (sgs-check).
Users are ML engineers renting GPUs on Lambda Cloud.

Find concrete weaknesses: ways an attacker (remote, another local user, a
malicious container image, a malicious model file or Python package) could
compromise the machine or its data despite the stack; defaults that are less
safe than claimed; checks in sgs-check that would report PASS on an insecure
machine; installer bugs that would leave the machine broken or less secure.

Rules:
- Only report things grounded in the code you were given. Cite file:line.
- For each finding: severity (high/medium/low), the defect in one sentence, a
  concrete scenario (inputs or state -> bad outcome), and a specific fix.
- Say "unverified" when you aren't sure a behaviour is real.
- No generic advice ("keep software updated"), no style nits.
- Rank most severe first. At most 12 findings. Be concise."""


def api_key():
    key = os.environ.get("OPENROUTER_API_KEY")
    env = ROOT / ".env"
    if not key and env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("OPENROUTER_API_KEY="):
                key = line.split("=", 1)[1].strip()
    if not key:
        sys.exit("No OPENROUTER_API_KEY in the environment or in .env")
    return key


def ask(model, key, system, user, timeout=600):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "temperature": 0.2,
        # Leave room for the answer: in round A the models spent ~45k tokens
        # reasoning, and one later returned no answer at all.
        "max_tokens": 48000,
        "reasoning": {"max_tokens": 24000},
    }).encode()
    req = urllib.request.Request(API, data=body, headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "X-Title": "secure-gpu-stack model review",
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.load(r)
            choice = data["choices"][0]
            text = choice["message"].get("content")
            if not text:
                if attempt < 2:
                    continue
                return f"ERROR: empty answer (finish_reason={choice.get('finish_reason')})", data.get("usage", {})
            return text, data.get("usage", {})
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if e.code == 402:
                return "ERROR: OpenRouter credits exhausted (HTTP 402); fall back to another reviewer", {}
            if e.code in (429, 500, 502, 503) and attempt < 2:
                time.sleep(10 * (attempt + 1))
                continue
            return f"ERROR: HTTP {e.code}: {detail}", {}
        except (urllib.error.URLError, TimeoutError, KeyError) as e:
            if attempt < 2:
                time.sleep(10)
                continue
            return f"ERROR: {e}", {}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+", type=pathlib.Path)
    ap.add_argument("--model", action="append", help="OpenRouter model id (repeatable)")
    ap.add_argument("--focus", default="", help="extra instructions for this round")
    ap.add_argument("--out", type=pathlib.Path, default=ROOT / "tests" / "results" / "model-review")
    args = ap.parse_args()

    parts = []
    for f in args.files:
        lines = f.read_text().splitlines()
        numbered = "\n".join(f"{i:4} {line}" for i, line in enumerate(lines, 1))
        # Excerpts from outside the repo (a scratch copy of one function) go by name.
        name = f.relative_to(ROOT) if f.is_absolute() and f.is_relative_to(ROOT) else (f.name if f.is_absolute() else f)
        parts.append(f"===== {name} =====\n{numbered}")
    user = "\n\n".join(parts)
    if args.focus:
        user = f"Focus for this round: {args.focus}\n\n{user}"

    key = api_key()
    models = args.model or DEFAULT_MODELS
    args.out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(len(models)) as pool:
        futures = {pool.submit(ask, m, key, SYSTEM, user): m for m in models}
        # Each answer is saved as soon as it arrives, so one failure can't lose the others.
        for fut in concurrent.futures.as_completed(futures):
            model = futures[fut]
            try:
                text, usage = fut.result()
            except Exception as e:  # noqa: BLE001 - report and keep the other models' answers
                text, usage = f"ERROR: {type(e).__name__}: {e}", {}
            failed += text.startswith("ERROR:")
            path = args.out / f"{stamp}-{model.replace('/', '_')}.md"
            path.write_text(f"# {model}\n\n{text}\n")
            print(f"{model}: {len(text)} chars, tokens {usage.get('prompt_tokens', '?')} in / "
                  f"{usage.get('completion_tokens', '?')} out -> {path.relative_to(ROOT)}"
                  + (f"  [{text[:90]}]" if text.startswith("ERROR:") else ""))
    sys.exit(1 if failed == len(models) else 0)


if __name__ == "__main__":
    main()
