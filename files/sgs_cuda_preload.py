"""Secure GPU Stack: make TensorFlow use its own CUDA 12 libraries.

TensorFlow 2.21 is built for CUDA 12; PyTorch and JAX for CUDA 13. Their cuDNN
and NCCL wheels install to the same paths, so in one environment the last one
installed silently overwrites the other. The stack therefore installs
TensorFlow's CUDA 12 wheels in their own hash-locked folder, /opt/sgs/tf-cuda12.

TensorFlow opens these libraries by name, and its own search path doesn't
reach that folder (it doesn't even reach its cuSOLVER wheel in a normal
install). Left alone, it quietly falls back to the CPU, or picks up whatever
copy is on the system path: Ubuntu's CUDA 12.0 libraries, or the CUDA 13 cuDNN
the stack installs system-wide. On the krabs test bench that cost TensorFlow
the GPU, then broke every GPU convolution. Its XLA compiler doesn't find the
folder's ptxas either; see _point_xla_at_cuda12.

Just before tensorflow's own code runs, this loads the folder's libraries by
full path, so TensorFlow's lookups by name find libraries that are already
loaded. It runs on a real `import tensorflow` only: libraries that merely ask
whether tensorflow is installed (importlib.util.find_spec, as Hugging Face
datasets does) don't trigger it, so PyTorch-only processes never get
TensorFlow's cuDNN and NCCL. Nothing is added to the system library path.
Loaded at startup by sgs-cuda-preload.pth.

It also keeps JAX on the CPU when no NVIDIA driver is loaded, and keeps
torch.compile's code caches out of /tmp (see the end of the file).

Library names are shared across CUDA versions, so a process that imports both
PyTorch and TensorFlow gets whichever cuDNN and NCCL loaded first. Keep GPU
work for the two frameworks in separate processes. A notebook that mixes them
dies without a word (on a Lambda A100: tensorflow first, then a PyTorch
convolution, is a floating point exception; the other order fails TensorFlow's
convolutions with cuDNN status 1008), so the second one to load warns first.
JAX and TensorFlow work together.
"""
import os
import sys

_TF_CUDA = "/opt/sgs/tf-cuda12"


def _preload():
    import ctypes
    import glob

    # Each library finds its own dependencies through its relative RUNPATH;
    # retry in case one still needs another loaded first.
    pending = sorted(glob.glob(os.path.join(_TF_CUDA, "nvidia", "*", "lib", "lib*.so*")))
    while pending:
        failed = []
        for lib in pending:
            try:
                ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                failed.append(lib)
        if len(failed) == len(pending):
            return
        pending = failed


def _point_xla_at_cuda12():
    """TensorFlow's XLA compiler (Keras model.fit uses it) runs ptxas and reads
    libdevice from a CUDA folder it looks for itself: PATH, /usr/local/cuda, or
    a CUDA 12 wheel next to tensorflow, never this folder. With no system CUDA
    toolkit (--no-cuda-toolkit) it finds none, and every compiled convolution
    fails ("Autotuner could not compile any configs"); with one, it uses that
    toolkit's CUDA 13 tools instead of TensorFlow's own. Found on M2 (RTX
    3080). XLA_FLAGS is inherited by child processes; JAX tolerates it (tested
    on M2). A --xla_gpu_cuda_data_dir the user set wins."""
    nvcc = os.path.join(_TF_CUDA, "nvidia", "cuda_nvcc")
    flags = os.environ.get("XLA_FLAGS", "")
    if "--xla_gpu_cuda_data_dir" not in flags and os.path.isfile(os.path.join(nvcc, "bin", "ptxas")):
        os.environ["XLA_FLAGS"] = (flags + " --xla_gpu_cuda_data_dir=" + nvcc).strip()


def _warn_mixed(first, second):
    # JAX isn't named: tensorflow.lite imports it, and JAX and TensorFlow
    # convolutions both worked in one process on the A100.
    import warnings
    warnings.warn(
        f"{first} is already loaded in this process. PyTorch (CUDA 13) and TensorFlow "
        f"(CUDA 12) need different builds of cuDNN and NCCL under the same names, so "
        f"{second}'s GPU convolutions and NCCL can fail here or crash the process. "
        f"Run GPU work for PyTorch and for TensorFlow in separate processes "
        f"(separate notebooks or scripts).",
        RuntimeWarning, stacklevel=3)


class _PreloadingLoader:
    """Wraps tensorflow's real loader; preloads only when the module executes."""

    def __init__(self, finder, loader):
        self._finder, self._loader = finder, loader

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        if self._finder in sys.meta_path:
            sys.meta_path.remove(self._finder)
            mixed = "torch" in sys.modules
            _preload()
            _point_xla_at_cuda12()
            _WarnAfterTensorFlow.tf_loaded = True
            # Last: with warnings as errors (pytest's filterwarnings), raising
            # here mustn't leave TensorFlow without its libraries.
            if mixed:
                _warn_mixed("PyTorch", "TensorFlow")
        # From here on tensorflow looks like any normally imported package.
        module.__loader__ = module.__spec__.loader = self._loader
        self._loader.exec_module(module)

    def __getattr__(self, name):
        return getattr(self._loader, name)


class _PreloadForTensorFlow:
    def find_spec(self, name, path=None, target=None):
        if name != "tensorflow":
            return None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(name, path, target)
            if spec is not None:
                if spec.loader is not None and hasattr(spec.loader, "exec_module"):
                    spec.loader = _PreloadingLoader(self, spec.loader)
                return spec
        return None


class _WarningLoader:
    """Wraps torch's real loader; warns only when the module executes."""

    def __init__(self, loader):
        self._loader = loader

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        _warn_mixed("TensorFlow", "PyTorch")
        module.__loader__ = module.__spec__.loader = self._loader
        self._loader.exec_module(module)

    def __getattr__(self, name):
        return getattr(self._loader, name)


class _WarnAfterTensorFlow:
    """PyTorch imported after TensorFlow loaded its CUDA 12 libraries. Like the
    preload, only a real import counts, not a find_spec probe."""

    tf_loaded = False

    def find_spec(self, name, path=None, target=None):
        if not self.tf_loaded or name != "torch":
            return None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(name, path, target)
            if spec is not None:
                if spec.loader is not None and hasattr(spec.loader, "exec_module"):
                    spec.loader = _WarningLoader(spec.loader)
                return spec
        return None


class _JaxWithoutDriver:
    """JAX's CUDA plugin crashes the whole process (a segfault, seen on the
    GPU-less test VM, in a notebook kernel too) instead of falling back to the
    CPU when no NVIDIA driver is loaded: a CPU-only machine, or the time
    between the install and its first reboot. CUDA can't work then anyway, so
    JAX defaults to the CPU. Decided when jax is imported, in the process that
    imports it: a long-running parent (the Jupyter server, started at boot
    perhaps before the driver loads) mustn't pass the choice on to kernels it
    starts later. With a driver nothing changes, and a JAX_PLATFORMS the user
    set wins."""

    # It stays in sys.meta_path: removing itself while the import system is
    # walking that list would make it skip the next finder.
    done = False

    def find_spec(self, name, path=None, target=None):
        if name == "jax" and not self.done:
            self.done = True
            if ("JAX_PLATFORMS" not in os.environ and not os.path.exists("/proc/driver/nvidia/version")
                    and not os.path.exists("/dev/nvidiactl")):
                os.environ["JAX_PLATFORMS"] = "cpu"
        return None


def _private_compile_caches():
    """torch.compile caches the code it generates, and runs it again on a later
    cache hit, in /tmp/torchinductor_<user>; its vendored CuTe kernels (quack)
    cache in /tmp/<user>. Any account can create those folders first, after
    every reboot empties /tmp, and then swap the cached code: on M2 nobody's
    code ran as ubuntu that way (finding 83). This puts both caches in the
    user's own ~/.cache, which other accounts can't reach.

    Parts of PyTorch (precompiled C++ headers, its newer on-disk caches) build
    the /tmp/torchinductor_<user> path themselves, whatever the setting says,
    from Python's temp folder. So Python processes also get a private temp
    folder, ~/.cache/tmp (TMPDIR), which closes every such predictable path at
    once; tempfile cleans up after itself as before.

    Settings the user made win, and an account without a writable home keeps
    the defaults. Environment variables only: torch isn't imported here."""
    home = os.path.expanduser("~")
    if not os.path.isdir(home) or not os.access(home, os.W_OK):
        return
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
    os.environ.setdefault("TORCHINDUCTOR_CACHE_DIR", os.path.join(base, "torchinductor"))
    os.environ.setdefault("QUACK_CACHE_DIR", os.path.join(base, "torch_vendor_quack"))
    if "TMPDIR" not in os.environ:
        tmp = os.path.join(base, "tmp")
        try:
            os.makedirs(tmp, mode=0o700, exist_ok=True)
        except OSError:
            return
        if os.path.isdir(tmp) and not os.path.islink(tmp) and os.stat(tmp).st_uid == os.getuid():
            os.environ["TMPDIR"] = tmp


sys.meta_path.insert(0, _JaxWithoutDriver())
_private_compile_caches()

if os.path.isdir(_TF_CUDA):
    sys.meta_path.insert(0, _PreloadForTensorFlow())
    sys.meta_path.insert(0, _WarnAfterTensorFlow())
