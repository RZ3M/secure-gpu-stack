# Secure GPU Stack: the M2 update: narration script

Each line starts at the time shown. To record your own voice, play
`secure-gpu-stack-m2-update-no-voice.mp4` and read along; the captions show each
line as it comes up. Regenerate with `node video/build-audio.mjs video/m2`.

## 0:00 Opening

- **0:01** Secure GPU Stack, version 0.1.1.
- **0:05** Since the last video, the stack has run on a modern GPU. Here's what that showed, what it found, and what's next.

## 0:14 A modern GPU

- **0:15** The last video ended on a limit: krabs's GPU is from 2016, too old for current PyTorch and JAX.
- **0:22** So the next machine was M2, a desktop with an RTX 3080. That's Ampere, the generation of Lambda's A10 and A100.
- **0:31** M2 doesn't run Ubuntu, so the card goes to an Ubuntu VM instead. That's also how a Lambda instance gets its GPU.

## 0:41 The published release

- **0:41** VM B booted the way a Lambda customer's machine would: a fresh Ubuntu image, our cloud-init file, and the published release, with its hash pinned.
- **0:50** Eight minutes later, unattended, it had rebooted with NVIDIA's open driver and kernel lockdown on.
- **0:56** That's the driver path every current Lambda GPU takes, and the old laptop couldn't test it.

## 1:04 What it found

- **1:04** And it found five problems the old laptop never could.
- **1:08** The big one: every TensorFlow convolution failed. TensorFlow's cuDNN pulled in parts of the system's other cuDNN: same version number, built for another CUDA.
- **1:18** Matrix multiplies still worked, so the check passed it.
- **1:22** Ubuntu's crash reporter quietly undid one of our kernel settings at every reboot.
- **1:27** The check's GPU test only multiplied matrices. TensorFlow's compiler couldn't find NVIDIA's assembler without a CUDA toolkit. And the check raised a false alarm for every new Jupyter user.
- **1:38** All five are fixed, verified in the VM, and released as version 0.1.1.

## 1:46 Lambda Stack, same GPU

- **1:47** Then VM A, for Lambda Stack, with Lambda's own install script.
- **1:52** It failed. Neither driver that Lambda's repository pins compiles on Ubuntu's current kernel, so a fresh Ubuntu 24.04 machine ends up with no GPU driver.
- **2:02** That's new finding fifteen, rated high.
- **2:06** To still compare, VM A got the same Ubuntu driver as ours, then Lambda's frameworks, installed exactly as its script does.

## 2:16 Head to head

- **2:16** Same GPU, same driver, same check.
- **2:20** Lambda Stack: nineteen pass, and seventeen warnings of its own. Secure GPU Stack: fifty-six pass, zero warnings.
- **2:29** On Lambda Stack, any account on the machine could use the GPU. On ours, another account tried 1.2 million times and got nowhere.
- **2:38** And speed: ResNet-50 trained at 902 images a second on Lambda Stack, and 919 on ours.
- **2:46** Bare metal managed 904, so the VM itself costs nothing measurable.

## 2:53 What's next

- **2:54** What's next.
- **2:55** Lambda's own cloud image: whether its JupyterLab is exposed, its default users, and Secure Boot.
- **3:02** Data-center GPUs and multi-GPU NCCL, on a real Lambda instance.
- **3:07** Whether existing Lambda Stack machines lose their driver at the next kernel update.
- **3:12** And a release signing key, so downloads are checked by signature, not just by hash.

## 3:19 Closing

- **3:24** Secure GPU Stack 0.1.1: tested on a modern GPU, and out now.
- **3:31** Next stop: a real Lambda instance.
