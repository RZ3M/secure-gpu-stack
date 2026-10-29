# Threat model

What Secure GPU Stack protects, from whom, and what it leaves to others. It's
written for the setting the stack is built for: a GPU machine rented on Lambda,
used by one ML engineer or a small team, reached over SSH. Each defense links to
where it's explained and where it was tested. "Finding N" refers to
[krabs-test-bench.md](krabs-test-bench.md).

## What's worth protecting

- **Model weights and training data,** often the most valuable thing on the
  machine.
- **Credentials:** Hugging Face, Weights & Biases and cloud keys, SSH keys, the
  Jupyter token.
- **The GPU itself:** a stolen GPU mines cryptocurrency or trains someone
  else's model on your bill.
- **The machine's integrity:** the stack, its updates, and `sgs-check`, which
  is only useful if it can't be quietly fooled.

## Who might attack, and what the stack does

| Attacker | How they'd get in | What the stack does | Tested by |
|---|---|---|---|
| **Someone on the internet** | An open port: Jupyter, a Docker-published port, SSH with a password | Firewall denies incoming traffic except SSH. The Jupyter server has no port, only a private socket ([design 5](design.md)). Docker publishes ports to localhost by default; a port published explicitly to `0.0.0.0` still goes around the firewall, and `sgs-check` warns. SSH accepts keys only, never root, and no X11 forwarding | The attack demo from another machine (9 of 9), `sgs-check` |
| **A malicious package or model** (supply chain) | `pip install`, `torch.load`, a pickled model, a notebook running it | The stack's Python is hash-locked, read-only, audited with `pip-audit`, and wheels only, so nothing runs at install (a malicious wheel still runs when imported). `torch.load` refuses code unless a caller passes `weights_only=False`; other pickle loaders (numpy with `allow_pickle`, joblib) aren't covered. `modelscan` is installed. Code in a notebook can't `sudo`, runs in a systemd sandbox, and can't reach the Docker socket | The user checks (booby-trapped models), findings 62 and 64 |
| **A compromised service or another account on the machine** | Reaching what the machine's own accounts can reach: the GPU driver, Jupyter, kernel features exploits use | GPU device files are for the `video` group only and locked, so NVIDIA's library, which reopens them whenever root uses the GPU, can't (finding 41; root itself still can). Jupyter is a socket only its user can open. io_uring, user namespaces (bypass included), line-discipline loading and unprivileged BPF are closed. Notebooks can't see other users' processes | A looping attacker: 0 opens in 17 million tries (findings 41, 45). Plants for every kernel setting (findings 48, 52, 54) |
| **Code that reaches for cloud metadata** (a malicious package, or a service a web request tricks: SSRF) | 169.254.169.254, where clouds hand out credentials and launch data | Closed to ordinary users and containers; root keeps it for cloud-init | Refused in 4 ms on a VM; `sgs-check` tries it as `nobody` (finding 69) |
| **A careless or malicious container** | `--privileged`, the Docker socket mounted, host folders or disks mounted in, a port published to everyone | No `docker` group. Containers can't gain privileges through setuid programs, get a GPU only when they ask, and publish to localhost by default. `sgs-check` names any running container that is root on the machine | Planted containers, each named with its reason (findings 61, 64) |
| **A tampered download or package source** | The install script, an apt repository, a swapped signing key | Release checksum and optional signature, checked by the cloud-init wrapper. HTTPS sources with pinned keys and no override pins. `sgs-check` re-verifies the keys and every installed file, Python and native, against its package's hashes | Nine signature cases, plants for keys and files (findings 37, 53) |
| **Drift over time** | A tuning guide loosens a setting, a driver goes stale, updates quietly stop | Security updates install automatically, with time limits on apt's jobs. `sgs-check` runs daily, and the login message shows its result. After a root compromise, both can be made to lie | Plants for each check; the daily run's stale and failed cases (findings 57–59) |

## What it doesn't protect against

- **Root, or anyone who becomes root.** Ubuntu's cloud images give the
  default user passwordless `sudo` (cloud-init's default; to be confirmed on a
  Lambda instance), so anything that runs as that user in an SSH session is
  one command from root. Root can undo every setting here and can make
  `sgs-check` lie. The stack keeps notebook code from that path (no `sudo`,
  no Docker socket), but not the user's own shell. One thing it does narrow:
  kernel lockdown keeps root out of the running kernel (no unsigned modules,
  no writing kernel memory), so getting a rootkit in takes a reboot with
  lockdown removed first ([design 7](design.md)).
- **Your own code, inside your own account.** Code in a notebook still runs
  as you: it can read your files, your data and your tokens, and send them
  out. The sandbox protects the machine and other users, not you from
  yourself.
- **Data leaving over the network**, by default. `sudo sgs-egress strict`
  (experimental, [design 11](design.md)) limits ordinary users and
  containers to a list of domains. Root isn't filtered. Without it, any
  process can reach any address. (Cloud metadata at 169.254.169.254 is closed
  to ordinary users and containers either way.)
- **Unknown bugs in the kernel or the NVIDIA driver.** The stack makes them
  harder to reach (fewer kernel features open, GPU files for `video` only)
  and keeps the driver patched. Anyone allowed to use the GPU can still
  reach the driver.
- **Other machines on the private network.** NCCL's traffic between nodes is
  neither authenticated nor encrypted. The firewall admits only SSH, so
  multi-node training means opening ports: open them to your own nodes only.
- **What a job leaves behind:** files in `/dev/shm`, swap, core dumps and
  caches (`~/.cache`, Triton's) can hold data or tokens after it ends. The
  stack doesn't clean them up.
- **Persistence:** code that runs as you can add a cron job, a user systemd
  unit, a line in your shell's startup files, an IPython startup script
  that runs in every notebook kernel, or an SSH key, and come back after a
  notebook restart. A container with the host's files mounted can do the
  same system-wide (`/etc/cron.d`, a systemd unit, `/etc/ld.so.preload`).
  The stack doesn't prevent that, but `sgs-check` reports any such change
  since you last accepted the record, in the daily login message too
  (findings 70, 73 and 74). Root that knows the check can hide from it.
- **Sharing the GPU with your team:** everyone in `video` shares the GPU and
  its driver. Only MIG partitions it, and changing MIG needs root.
- **Lambda's side of the machine:** the hypervisor, the network between
  machines, physical access, and Lambda's dashboard and API.
- **Your laptop and your SSH keys.** If those are taken, the attacker logs in
  as you. Forwarding your SSH agent (`ssh -A`) is still allowed, and while
  you're connected anyone with root on the server can use it. Turning it
  off is one line of SSH configuration, at the cost of cloning private
  repositories on the server with your laptop's key.
- **What models say or do.** Guardrails and red-teaming are out of scope.

## Known gaps

- **Users' own Python environments** (`sgs-venv`) install whatever you ask
  for, build scripts included. Only the stack's own environment is
  hash-locked.
- **One localhost port per notebook kernel remains:** ipykernel's pipe for
  output from subprocesses, hard-coded to TCP. It drops anything without its
  random key (finding 49).
- **Untested here, because krabs has no such hardware:** NVSwitch and NVLink
  device files, MIG, and InfiniBand from notebooks. They're in the
  [Lambda test plan](lambda-test-plan.md).
- **Who holds the release signing key** isn't decided yet. Until it is, take
  the release checksum from somewhere other than the download host.
- **A machine whose user is in the `docker` group** is root for that user.
  The stack never adds one, and `sgs-check` warns.
