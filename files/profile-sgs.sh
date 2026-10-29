# Secure GPU Stack: make the stack's Python and the CUDA toolkit the defaults,
# so `python3 -c "import torch"` and `nvcc` work in every login shell, as on
# Lambda Stack.
# They go first on everyone's PATH, root's included, so only while root owns
# them and nobody else can write to them: otherwise a planted `python3` there
# would run in root's next login shell.
for sgs_dir in /usr/local/cuda/bin /opt/sgs/venv/bin; do
  case ":$PATH:" in
    *":$sgs_dir:"*) ;;
    *) [ -d "$sgs_dir" ] && [ "$(stat -L -c %u "$sgs_dir")" = 0 ] \
         && [ -z "$(find -L "$sgs_dir" -maxdepth 0 -perm /022)" ] && PATH="$sgs_dir:$PATH" ;;
  esac
done
unset sgs_dir
export PATH

# Hugging Face libraries don't send usage telemetry.
export HF_HUB_DISABLE_TELEMETRY=1
