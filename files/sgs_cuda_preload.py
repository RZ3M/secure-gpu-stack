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
the GPU, then broke every GPU convolution.

Just before tensorflow's own code runs, this loads the folder's libraries by
full path, so TensorFlow's lookups by name find libraries that are already
loaded. It runs on a real `import tensorflow` only: libraries that merely ask
whether tensorflow is installed (importlib.util.find_spec, as Hugging Face
datasets does) don't trigger it, so PyTorch-only processes never get
TensorFlow's cuDNN and NCCL. Nothing is added to the system library path.
Loaded at startup by sgs-cuda-preload.pth.

It also keeps JAX on the CPU when no NVIDIA driver is loaded (see the end of
the file).

Library names are shared across CUDA versions, so a process that imports both
PyTorch and TensorFlow gets whichever cuDNN and NCCL loaded first. Keep GPU
work for the two frameworks in separate processes.
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


class _PreloadingLoader:
    """Wraps tensorflow's real loader; preloads only when the module executes."""

    def __init__(self, finder, loader):
        self._finder, self._loader = finder, loader

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        if self._finder in sys.meta_path:
            sys.meta_path.remove(self._finder)
            _preload()
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


sys.meta_path.insert(0, _JaxWithoutDriver())

if os.path.isdir(_TF_CUDA):
    sys.meta_path.insert(0, _PreloadForTensorFlow())
