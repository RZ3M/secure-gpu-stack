# Secure GPU Stack walkthrough: narration script

Each line starts at the time shown. To record your own voice, play
`secure-gpu-stack-no-voice.mp4` and read along; the captions show each
line as it comes up. Regenerate with `node video/build-audio.mjs`.

## 0:00 Opening

- **0:01** This is how a lot of GPU machines get set up.
- **0:04** One command, piped straight into a shell, that ends up running as root.
- **0:09** Nothing checks what it runs.

## 0:12 Title

- **0:13** This is Secure GPU Stack.
- **0:16** The same tools as Lambda Stack, with safe defaults, and the proof to back them.

## 0:22 The brief

- **0:22** The brief: build an alternative to Lambda Stack, with security built in.
- **0:28** Lambda Stack is the driver, CUDA, cuDNN, NCCL, PyTorch, TensorFlow, JAX, Jupyter and Docker, in one install.
- **0:37** My first plan was a locked-down inference appliance.
- **0:41** The feedback was clear: make it a real alternative.
- **0:45** So before writing any code, I asked the questions that would change the design.
- **0:50** Who uses it? People already renting GPUs on Lambda.
- **0:55** What's in it? Everything Lambda Stack has.
- **0:58** How does it ship? The same way: one command.
- **1:01** And reaching Jupyter through an SSH tunnel is acceptable.

## 1:06 The audit

- **1:07** Then I audited the thing I was replacing: fourteen findings, each with evidence and a way to reproduce it.
- **1:14** The worst one: Lambda's apt pin, at priority 1001, outranks Ubuntu's own security channel.
- **1:21** Ubuntu ships driver 580.178, with this year's security fixes.
- **1:27** The pin holds machines on 580.105, and apt upgrade will never move them.
- **1:35** The default driver branch is end of life.
- **1:38** The ML packages carry 44 known vulnerability advisories, some of them code execution when a model loads.
- **1:45** The repository is plain HTTP. One key is trusted for every repository.
- **1:52** And the install verifies nothing before it runs as root.

## 1:56 Three rules

- **1:57** That gave me three rules.
- **1:59** Same experience: if code runs on Lambda Stack, it runs here.
- **2:03** Safe defaults: nothing reachable but SSH, least privilege, and patches that actually arrive.
- **2:10** And proof: a check command, sgs-check, that shows the difference on any machine.

## 2:17 The build

- **2:18** Here's what the installer builds, layer by layer.
- **2:21** Ubuntu 24.04, hardened: a firewall, keys-only SSH, pinned kernel settings, and audit logging.
- **2:30** NVIDIA's long-term R580 driver, from Ubuntu's own archive, so security fixes keep flowing.
- **2:37** CUDA, cuDNN and NCCL, over HTTPS, each source with its own pinned key.
- **2:44** Docker without the root-equivalent docker group, and published ports that stay on localhost.
- **2:49** The frameworks live in a read-only, hash-locked environment, apart from the system Python.
- **2:55** Jupyter sits on a private socket, inside a sandbox.
- **2:59** And sgs-check audits all of it, every day.
- **3:03** It ships as one verifiable command, with a checksum, a signature, a cloud-init wrapper for Lambda, and an SBOM.

## 3:13 Where it was tested

- **3:13** I tested in three places, each harder than the last.
- **3:17** Local virtual machines first, comparing a Lambda baseline with my stack.
- **3:22** Then krabs: my own laptop, with a GTX 1070.
- **3:27** It's a lived-in machine. 198 days of uptime, Docker Desktop, an old CUDA install.
- **3:34** Messier than any fresh cloud image, which is exactly why I used it.
- **3:39** The third, a real Lambda instance, is next.

## 3:44 What krabs found

- **3:44** The first real install found fifteen problems the VMs never could.
- **3:49** On Ubuntu's newer kernels, the GPU would have been dead after a reboot.
- **3:54** TensorFlow quietly ran on the CPU.
- **3:58** PyTorch's cuDNN and NCCL were silently overwritten by TensorFlow's, seventy files, while pip check said everything was fine.
- **4:07** Automatic updates looked on, but a hung job had blocked every update for 99 days.
- **4:13** And my own GPU check said PASS when JAX couldn't compute at all.
- **4:18** The lesson: a check that can't fail is worse than no check.

## 4:24 The method

- **4:25** So every round follows the same loop.
- **4:28** Form a hypothesis. Attack the real machine, or plant the bad state.
- **4:33** Fix it. Then prove the fix with a negative control: the check has to fail when it should.
- **4:38** Then hand it to independent reviewers: a fresh code review with no context, and two open-weight models, DeepSeek and GLM, as read-only red teamers.
- **4:49** Their findings are untrusted until reproduced. Many didn't hold up, and I wrote down why.
- **4:55** One I had dismissed was right. GLM said twice that Docker and NVIDIA updates never auto-installed.
- **5:02** My own check had cut a label short.
- **5:05** That loop produced seventy-six findings, each one fixed or disproved on a real machine.

## 5:13 Spotlight: the GPU device files

- **5:14** The biggest one: by Ubuntu's default, the GPU's device files are open to every account on the machine, service accounts included.
- **5:22** My first fix re-applied the permissions after every change. A looping attacker still got in, twenty times out of twenty.
- **5:30** NVIDIA's own library reopens the files whenever root uses the GPU. So I locked each file with a read-only bind mount. Zero in 2.9 million tries.
- **5:40** Reviewing the lock exposed a 45-millisecond window when the files are created. Ten out of ten.
- **5:47** Creating them closed from the start fixed that.
- **5:50** Zero opens in seventeen million tries, verified across four reboots.

## 5:57 Same loop, many doors

- **5:57** Same loop, many doors.
- **6:00** Jupyter listened on localhost, where any account got an answer. Now it's a private socket, reached through an SSH tunnel.
- **6:07** Its sandbox took systemd's exposure score from 8.5 to 2.2.
- **6:13** Cloud metadata is for root only, host-network containers included.
- **6:17** An aa-exec bypass of Ubuntu's user-namespace restriction is closed, and io_uring is for root only.
- **6:24** Kernel lockdown is on, and steps aside when it would cost the GPU its driver.
- **6:30** And sgs-check watches seventy-one places where malicious code makes itself permanent.

## 6:37 Tested non-findings

- **6:37** Not every worry is real.
- **6:39** I tested whether a crashing job leaks its memory to other users through core dumps.
- **6:44** It doesn't. The kernel writes them private to their owner.
- **6:48** GPU memory, too, comes back zeroed between processes.
- **6:53** Both are written down, so nobody chases them again.

## 6:57 The results

- **6:58** The results. Same check, on identical VMs.
- **7:01** Lambda's stack: sixteen pass, fifteen warnings. Secure GPU Stack: forty-seven pass, zero warnings.
- **7:10** Known vulnerabilities in the ML packages: from forty-four to zero.
- **7:15** On the real GPU: fifty-five pass. The three warnings are krabs's own, from before the stack.
- **7:21** The attack demo passes nine of nine from another machine.
- **7:25** And the hardening costs nothing measurable: a GPU matrix multiply in the sandboxed notebook ran within half a percent of a plain shell.

## 7:35 What isn't proven yet

- **7:36** What isn't proven yet.
- **7:37** krabs's Pascal GPU can't run current PyTorch or JAX, so that needs a current GPU.
- **7:43** So do Lambda's own image, NVSwitch, and a speed comparison with Lambda Stack on the same hardware.
- **7:50** Strict outbound mode is still experimental.
- **7:53** The test plan for all of it is written, and waiting for a Lambda instance.

## 7:59 How I work

- **8:00** So, how I work.
- **8:02** Understand the incumbent before building.
- **8:05** Ask the questions that change the design.
- **8:08** Test on the messiest machine you have.
- **8:11** Give every check a negative control.
- **8:13** Treat every reviewer, human or AI, as untrusted until reproduced. I built this with an AI coding agent, and that rule applied to it too.
- **8:23** And write down the misses, the rejections and the non-findings. They're results too.

## 8:31 Closing

- **8:37** Secure GPU Stack. The same tools, safe defaults, and the proof to back them.
- **8:43** Next stop: a real Lambda instance.
