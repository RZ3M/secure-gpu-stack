// Narration for the Secure GPU Stack walkthrough video.
//
// Each scene's lines are spoken in order and shown as captions. A line is a
// string, or { t, s, gap }: t is the caption, s overrides what the voice says
// (for pronunciation), gap is the pause before the line in seconds.
// build-audio.mjs turns this into build/timeline.js and build/narration.wav;
// stage.html times every animation to these lines.

globalThis.SCRIPT = {
  // HeyGen Voice on OpenRouter's speech endpoint.
  model: 'heygen/heygen-voice-1-turbo:free',
  voice: 'noelle',
  fps: 30,
  scenes: [
    {
      id: 'cold', chapter: null, lead: 1.0, tail: 1.4,
      lines: [
        'This is how a lot of GPU machines get set up.',
        'One command, piped straight into a shell, that ends up running as root.',
        { t: 'Nothing checks what it runs.', gap: 0.6 },
      ],
    },
    {
      id: 'title', chapter: null, lead: 1.6, tail: 1.6,
      lines: [
        'This is Secure GPU Stack.',
        'The same tools as Lambda Stack, with safe defaults, and the proof to back them.',
      ],
    },
    {
      id: 'brief', chapter: 'The brief', lead: 0.6, tail: 1.2,
      lines: [
        'The brief: build an alternative to Lambda Stack, with security built in.',
        'Lambda Stack is the driver, CUDA, cuDNN, NCCL, PyTorch, TensorFlow, JAX, Jupyter and Docker, in one install.',
        { t: 'My first plan was a locked-down inference appliance.', gap: 0.5 },
        'The feedback was clear: make it a real alternative.',
        { t: 'So before writing any code, I asked the questions that would change the design.', gap: 0.6 },
        'Who uses it? People already renting GPUs on Lambda.',
        "What's in it? Everything Lambda Stack has.",
        'How does it ship? The same way: one command.',
        'And reaching Jupyter through an SSH tunnel is acceptable.',
      ],
    },
    {
      id: 'audit', chapter: 'The audit', lead: 0.6, tail: 1.2,
      lines: [
        'Then I audited the thing I was replacing: fourteen findings, each with evidence and a way to reproduce it.',
        { t: "The worst one: Lambda's apt pin, at priority 1001, outranks Ubuntu's own security channel.", gap: 0.6 },
        { t: "Ubuntu ships driver 580.178, with this year's security fixes.", s: "Ubuntu ships driver 580 point 178, with this year's security fixes." },
        { t: 'The pin holds machines on 580.105, and apt upgrade will never move them.', s: 'The pin holds machines on 580 point 105, and apt upgrade will never move them.' },
        { t: 'The default driver branch is end of life.', gap: 0.6 },
        'The ML packages carry 44 known vulnerability advisories, some of them code execution when a model loads.',
        { t: 'The repository is plain HTTP. One key is trusted for every repository.', gap: 0.5 },
        'And the install verifies nothing before it runs as root.',
      ],
    },
    {
      id: 'rules', chapter: 'Three rules', lead: 0.5, tail: 1.4,
      lines: [
        'That gave me three rules.',
        'Same experience: if code runs on Lambda Stack, it runs here.',
        'Safe defaults: nothing reachable but SSH, least privilege, and patches that actually arrive.',
        'And proof: a check command, sgs-check, that shows the difference on any machine.',
      ],
    },
    {
      id: 'build', chapter: 'The build', lead: 0.6, tail: 1.4,
      lines: [
        "Here's what the installer builds, layer by layer.",
        'Ubuntu 24.04, hardened: a firewall, keys-only SSH, pinned kernel settings, and audit logging.',
        "NVIDIA's long-term R580 driver, from Ubuntu's own archive, so security fixes keep flowing.",
        'CUDA, cuDNN and NCCL, over HTTPS, each source with its own pinned key.',
        'Docker without the root-equivalent docker group, and published ports that stay on localhost.',
        'The frameworks live in a read-only, hash-locked environment, apart from the system Python.',
        'Jupyter sits on a private socket, inside a sandbox.',
        'And sgs-check audits all of it, every day.',
        { t: 'It ships as one verifiable command, with a checksum, a signature, a cloud-init wrapper for Lambda, and an SBOM.', gap: 0.6 },
      ],
    },
    {
      id: 'bench', chapter: 'Where it was tested', lead: 0.5, tail: 1.4,
      lines: [
        'I tested in three places, each harder than the last.',
        'Local virtual machines first, comparing a Lambda baseline with my stack.',
        'Then krabs: my own laptop, with a GTX 1070.',
        "It's a lived-in machine. 198 days of uptime, Docker Desktop, an old CUDA install.",
        'Messier than any fresh cloud image, which is exactly why I used it.',
        { t: 'The third, a real Lambda instance, is next.', gap: 0.5 },
      ],
    },
    {
      id: 'broke', chapter: 'What krabs found', lead: 0.5, tail: 1.8,
      lines: [
        'The first real install found fifteen problems the VMs never could.',
        "On Ubuntu's newer kernels, the GPU would have been dead after a reboot.",
        'TensorFlow quietly ran on the CPU.',
        "PyTorch's cuDNN and NCCL were silently overwritten by TensorFlow's, seventy files, while pip check said everything was fine.",
        'Automatic updates looked on, but a hung job had blocked every update for 99 days.',
        "And my own GPU check said PASS when JAX couldn't compute at all.",
        { t: "The lesson: a check that can't fail is worse than no check.", gap: 0.8 },
      ],
    },
    {
      id: 'loop', chapter: 'The method', lead: 0.5, tail: 1.6,
      lines: [
        'So every round follows the same loop.',
        'Form a hypothesis. Attack the real machine, or plant the bad state.',
        'Fix it. Then prove the fix with a negative control: the check has to fail when it should.',
        'Then hand it to independent reviewers: a fresh code review with no context, and two open-weight models, DeepSeek and GLM, as read-only red teamers.',
        "Their findings are untrusted until reproduced. Many didn't hold up, and I wrote down why.",
        { t: 'One I had dismissed was right. GLM said twice that Docker and NVIDIA updates never auto-installed.', gap: 0.5 },
        'My own check had cut a label short.',
        { t: 'That loop produced seventy-six findings, each one fixed or disproved on a real machine.', gap: 0.6 },
      ],
    },
    {
      id: 'gpu', chapter: 'Spotlight: the GPU device files', lead: 0.6, tail: 1.8,
      lines: [
        "The biggest one: by Ubuntu's default, the GPU's device files are open to every account on the machine, service accounts included.",
        'My first fix re-applied the permissions after every change. A looping attacker still got in, twenty times out of twenty.',
        "NVIDIA's own library reopens the files whenever root uses the GPU. So I locked each file with a read-only bind mount. Zero in 2.9 million tries.",
        'Reviewing the lock exposed a 45-millisecond window when the files are created. Ten out of ten.',
        'Creating them closed from the start fixed that.',
        { t: 'Zero opens in seventeen million tries, verified across four reboots.', gap: 0.5 },
      ],
    },
    {
      id: 'doors', chapter: 'Same loop, many doors', lead: 0.5, tail: 1.6,
      lines: [
        'Same loop, many doors.',
        "Jupyter listened on localhost, where any account got an answer. Now it's a private socket, reached through an SSH tunnel.",
        "Its sandbox took systemd's exposure score from 8.5 to 2.2.",
        'Cloud metadata is for root only, host-network containers included.',
        "An aa-exec bypass of Ubuntu's user-namespace restriction is closed, and io_uring is for root only.",
        'Kernel lockdown is on, and steps aside when it would cost the GPU its driver.',
        'And sgs-check watches seventy-one places where malicious code makes itself permanent.',
      ],
    },
    {
      id: 'nonfinding', chapter: 'Tested non-findings', lead: 0.5, tail: 1.6,
      lines: [
        'Not every worry is real.',
        'I tested whether a crashing job leaks its memory to other users through core dumps.',
        "It doesn't. The kernel writes them private to their owner.",
        { t: 'GPU memory, too, comes back zeroed between processes.', gap: 0.5 },
        'Both are written down, so nobody chases them again.',
      ],
    },
    {
      id: 'results', chapter: 'The results', lead: 0.5, tail: 2.0,
      lines: [
        'The results. Same check, on identical VMs.',
        "Lambda's stack: sixteen pass, fifteen warnings. Secure GPU Stack: forty-seven pass, zero warnings.",
        'Known vulnerabilities in the ML packages: from forty-four to zero.',
        "On the real GPU: fifty-five pass. The three warnings are krabs's own, from before the stack.",
        'The attack demo passes nine of nine from another machine.',
        'And the hardening costs nothing measurable: a GPU matrix multiply in the sandboxed notebook ran within half a percent of a plain shell.',
      ],
    },
    {
      id: 'limits', chapter: "What isn't proven yet", lead: 0.5, tail: 1.6,
      lines: [
        "What isn't proven yet.",
        "krabs's Pascal GPU can't run current PyTorch or JAX, so that needs a current GPU.",
        "So do Lambda's own image, NVSwitch, and a speed comparison with Lambda Stack on the same hardware.",
        'Strict outbound mode is still experimental.',
        'The test plan for all of it is written, and waiting for a Lambda instance.',
      ],
    },
    {
      id: 'how', chapter: 'How I work', lead: 0.5, tail: 2.0,
      lines: [
        'So, how I work.',
        'Understand the incumbent before building.',
        'Ask the questions that change the design.',
        'Test on the messiest machine you have.',
        'Give every check a negative control.',
        'Treat every reviewer, human or AI, as untrusted until reproduced. I built this with an AI coding agent, and that rule applied to it too.',
        "And write down the misses, the rejections and the non-findings. They're results too.",
      ],
    },
    {
      id: 'outro', chapter: null, lead: 6.0, tail: 3.6,
      lines: [
        'Secure GPU Stack. The same tools, safe defaults, and the proof to back them.',
        { t: 'Next stop: a real Lambda instance.', gap: 0.5 },
      ],
    },
  ],
};
