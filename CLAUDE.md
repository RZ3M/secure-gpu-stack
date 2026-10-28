# Secure GPU inference stack

Project context for Claude sessions in this folder. Keep it current as decisions
are made.

## The task

- **The challenge:** an employer challenge. Improve the starting image that boots
  on a rented GPU so it's more secure than Lambda Stack. Lambda Stack targets ML
  researcher convenience, not security.
- **The company:** called "blackbox" by the user. It **sells inference**, so the
  target is a hardened **inference-serving node**, not a research workstation.
- **In scope:** the machine and its software stack: OS, NVIDIA driver and CUDA,
  containers, the inference engine, and the network.
- **Out of scope:** model and agent behavior (guardrails, jailbreaks, red-teaming).
  NVIDIA NeMo Helix was considered and set aside for that reason.
- **GPUs:** rented on Lambda (lambda.ai) with a corporate card. The user handles
  account signup and payment; Claude never enters card details. A Lambda API key,
  when there is one, lives in an environment variable such as `LAMBDA_API_KEY`,
  never in a file.

## Lambda facts (from docs.lambda.ai, checked 2026-10-27)

- **Base images:** there's no documented way to upload a custom image. The API
  offers four:
  - **Lambda Stack:** the default.
  - **Lambda Stack Legacy:** for V100s.
  - **GPU Base:** driver, CUDA, cuDNN, NCCL, Docker.
  - **Ubuntu Server:** plain Ubuntu.

  Each comes in 22.04 and 24.04. Only Lambda Stack also has an arm64 build.
- **cloud-init:** user data can be passed at launch, through the API only.
- **Network:** by default only port 22 is open. Firewall rules (global and
  per-instance) are managed in the console or the API.
- **Patching:** Lambda's own docs say `apt full-upgrade` and `dist-upgrade`
  currently fail on Lambda Stack 24.04 and GPU Base 24.04. That's a finding
  worth highlighting.
- **Jupyter:** the default image runs JupyterLab.

## Approach

The image is built from three layers:

1. **Base:** Ubuntu Server 24.04.
2. **Hardening:** a cloud-init file that hardens the machine and installs a
   pinned NVIDIA driver and Container Toolkit from NVIDIA's signed repo.
3. **Workload:** a hardened container that runs the inference engine.

## Design rules for the inference node

1. Appliance, not workstation: no Jupyter, compilers or dev tools.
2. One door in: only the company's gateway can reach the inference port.
3. No door out: block outbound traffic after the weights load, except logs and
   metrics. This is the biggest differentiator from Lambda Stack.
4. Locked-down engine container: non-root, read-only filesystem, minimal Linux
   capabilities.
5. Protected weights: safetensors only, checksums verified, mounted read-only.
6. No prompt logging by default.
7. Replace, don't repair: no routine SSH; roll out new images instead.
8. Know what's running: pinned versions, an SBOM, signed images.

## Deliverables

1. A threat model covering assets, attackers, entry points and defenses.
2. The cloud-init hardening file.
3. The hardened inference container.
4. An audit script that scores a machine.
5. A before/after report comparing stock Lambda Stack with this image, including
   an attack demo and a check that the GPU still works and stays fast.

## Status

- [x] **Exercise 1** (`exercise-01/`): local Multipass VMs, plain vs. hardened.
  Tested 2026-10-28: plain scored 4 PASS / 3 WARN, hardened 8 PASS / 1 WARN.
  The remaining WARN is outbound traffic, on purpose.
- [ ] The user runs exercise 1 themselves.
- [ ] Ask the assigner the questions in `questions-for-assigner.md` and record
  the answers there.
- [ ] Exercise 2: block outbound traffic (egress allowlist) and allow inbound
  only on the gateway port.
- [ ] Baseline audit of stock Lambda Stack on a real Lambda GPU (about an hour).
- [ ] Serve a small open model with vLLM locally, then in a locked-down container.
- [ ] Build the real image for Lambda, then run the before/after comparison.

## Environment notes

- **The Mac:** Apple Silicon (arm64), with Multipass 1.16.4 installed through
  Homebrew. Local VMs are arm64. Lambda's Ubuntu Server and GPU Base images are
  x86-64 only.
- **Multipass and `permissions`:** Multipass rewrites the user-data it's given
  and turns `permissions: "0644"` into the integer 420, which fails cloud-init's
  schema check. Leave `permissions` out when 0644 (the default) is wanted.
- **Claude's Bash sandbox:** it blocks the multipass client from reaching VMs
  ("No route to host"). Run `multipass exec` and `multipass transfer` with the
  sandbox disabled. `nc` and `ssh` to VM IPs work either way.

## Working with the user

- The user is new to infrastructure security. Explain in plain language, define
  terms the first time they come up, and give step-by-step instructions.
- Learning path agreed so far:
  1. Linux server basics
  2. GPU software layers
  3. Docker
  4. cloud-init
  5. Hardening
  6. ML-specific risks
  7. How inference serving works (vLLM)
  8. Reverse proxies and TLS
  9. Network rules
  10. Container lockdown
