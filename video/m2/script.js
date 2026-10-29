// Narration for the M2 update video: what changed since the walkthrough.
//
// Same format as ../script.js: each scene's lines are spoken in order and
// shown as captions. A line is a string, or { t, s, gap }: t is the caption,
// s is what the voice says instead (for words the shared pronunciation list
// in build-audio.mjs doesn't cover), gap is the pause before the line.
// Build with `node video/build-audio.mjs video/m2`.

globalThis.SCRIPT = {
  // HeyGen Voice on OpenRouter's speech endpoint, as in the walkthrough.
  model: 'heygen/heygen-voice-1-turbo:free',
  voice: 'noelle',
  fps: 30,
  name: 'secure-gpu-stack-m2-update',
  title: 'Secure GPU Stack: the M2 update',
  scenes: [
    {
      id: 'title', chapter: null, lead: 1.6, tail: 1.4,
      lines: [
        { t: 'Secure GPU Stack, version 0.1.1.', s: 'Secure GPU Stack, version oh point one point one.' },
        "Since the last video, the stack has run on a modern GPU. Here's what that showed, what it found, and what's next.",
      ],
    },
    {
      id: 'm2', chapter: 'A modern GPU', lead: 0.5, tail: 1.4,
      lines: [
        "The last video ended on a limit: krabs's GPU is from 2016, too old for current PyTorch and JAX.",
        { t: "So the next machine was M2, a desktop with an RTX 3080. That's Ampere, the generation of Lambda's A10 and A100.",
          s: "So the next machine was M two, a desktop with an R T X thirty eighty. That's Ampere, the generation of Lambda's A ten and A one hundred." },
        { t: "M2 doesn't run Ubuntu, so the card goes to an Ubuntu VM instead. That's also how a Lambda instance gets its GPU.",
          s: "M two doesn't run Ubuntu, so the card goes to an Ubuntu V M instead. That's also how a Lambda instance gets its GPU." },
      ],
    },
    {
      id: 'install', chapter: 'The published release', lead: 0.5, tail: 1.4,
      lines: [
        { t: "VM B booted the way a Lambda customer's machine would: a fresh Ubuntu image, our cloud-init file, and the published release, with its hash pinned.",
          s: "V M B booted the way a Lambda customer's machine would: a fresh Ubuntu image, our cloud init file, and the published release, with its hash pinned." },
        "Eight minutes later, unattended, it had rebooted with NVIDIA's open driver and kernel lockdown on.",
        "That's the driver path every current Lambda GPU takes, and the old laptop couldn't test it.",
      ],
    },
    {
      id: 'found', chapter: 'What it found', lead: 0.5, tail: 1.6,
      lines: [
        'And it found five problems the old laptop never could.',
        "The big one: every TensorFlow convolution failed. TensorFlow's cuDNN pulled in parts of the system's other cuDNN: same version number, built for another CUDA.",
        'Matrix multiplies still worked, so the check passed it.',
        "Ubuntu's crash reporter quietly undid one of our kernel settings at every reboot.",
        "The check's GPU test only multiplied matrices. TensorFlow's compiler couldn't find NVIDIA's assembler without a CUDA toolkit. And the check raised a false alarm for every new Jupyter user.",
        { t: 'All five are fixed, verified in the VM, and released as version 0.1.1.',
          s: 'All five are fixed, verified in the V M, and released as version oh point one point one.' },
      ],
    },
    {
      id: 'lambda', chapter: 'Lambda Stack, same GPU', lead: 0.5, tail: 1.6,
      lines: [
        { t: "Then VM A, for Lambda Stack, with Lambda's own install script.", s: "Then V M A, for Lambda Stack, with Lambda's own install script." },
        "It failed. Neither driver that Lambda's repository pins compiles on Ubuntu's current kernel, so a fresh Ubuntu 24.04 machine ends up with no GPU driver.",
        "That's new finding fifteen, rated high.",
        { t: "To still compare, VM A got the same Ubuntu driver as ours, then Lambda's frameworks, installed exactly as its script does.",
          s: "To still compare, V M A got the same Ubuntu driver as ours, then Lambda's frameworks, installed exactly as its script does." },
      ],
    },
    {
      id: 'compare', chapter: 'Head to head', lead: 0.5, tail: 1.8,
      lines: [
        'Same GPU, same driver, same check.',
        'Lambda Stack: nineteen pass, and seventeen warnings of its own. Secure GPU Stack: fifty-six pass, zero warnings.',
        'On Lambda Stack, any account on the machine could use the GPU. On ours, another account tried 1.2 million times and got nowhere.',
        { t: 'And speed: ResNet-50 trained at 902 images a second on Lambda Stack, and 919 on ours.',
          s: 'And speed: Res Net fifty trained at nine hundred and two images a second on Lambda Stack, and nine hundred and nineteen on ours.' },
        { t: 'Bare metal managed 904, so the VM itself costs nothing measurable.',
          s: 'Bare metal managed nine hundred and four, so the V M itself costs nothing measurable.' },
      ],
    },
    {
      id: 'next', chapter: "What's next", lead: 0.5, tail: 1.6,
      lines: [
        "What's next.",
        "Lambda's own cloud image: whether its JupyterLab is exposed, its default users, and Secure Boot.",
        'Data-center GPUs and multi-GPU NCCL, on a real Lambda instance.',
        'Whether existing Lambda Stack machines lose their driver at the next kernel update.',
        'And a release signing key, so downloads are checked by signature, not just by hash.',
      ],
    },
    {
      id: 'outro', chapter: null, lead: 5.4, tail: 3.6,
      lines: [
        { t: 'Secure GPU Stack 0.1.1: tested on a modern GPU, and out now.',
          s: 'Secure GPU Stack oh point one point one: tested on a modern GPU, and out now.' },
        { t: 'Next stop: a real Lambda instance.', gap: 0.5 },
      ],
    },
  ],
};
