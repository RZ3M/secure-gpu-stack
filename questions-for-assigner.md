# Questions for the person who assigned the task

If there's only time for a few, ask the ★ ones first: those answers decide what
gets built. Fill in each answer as it comes back.

## Feedback so far

- **2026-10-28:** they want it similar to Lambda Stack, an alternative to it.

## Follow-ups on that feedback

1. ★ Who will use it: our own engineers on development and training machines,
   our inference servers, or customers?
   - Answer: people who already rent GPUs on Lambda. It's an alternative to
     Lambda Stack for them. (2026-10-28)
2. ★ Should it include everything Lambda Stack has (PyTorch, TensorFlow, JAX,
   JupyterLab, Docker), or is PyTorch-first fine?
   - Answer: yes, everything Lambda Stack has. (2026-10-28)
3. ★ How should it ship: an install script for any Ubuntu machine (like Lambda
   Stack), a ready-to-launch setup on Lambda, a Docker image, or a mix?
   - Answer: the same way Lambda Stack is set up. (2026-10-28)
4. Should it include inference tools such as vLLM or TensorRT-LLM, since
   that's our business?
   - Answer:
5. ★ How strict can the defaults be? For example, is it OK if Jupyter needs an
   SSH tunnel, or Docker needs sudo? Where's the line between safe and annoying?
   - Answer: an SSH tunnel is acceptable. We'll judge how strict the other
     defaults should be as we go. (2026-10-28)

## What they want

6. ★ What should I hand in at the end: a working stack, a written
   recommendation, a live demo, or a mix? How will it be judged?
   - Answer:
7. When is it due, and can we check in partway through?
   - Answer:

## Our setup today

8. Are we on Lambda now? If so, which images do we use (Lambda Stack, GPU Base,
   plain Ubuntu)? Should this also work on other providers or our own hardware?
   - Answer:
9. Which GPUs do we use (H100, B200, A100, ...)?
   - Answer:
10. How do machines get set up and updated today: Kubernetes, Terraform,
    scripts, by hand over SSH?
    - Answer:

## What worries them most

11. ★ What's the biggest concern: leaked data or code, stolen model weights,
    hijacked machines, or passing compliance and customer security reviews?
    - Answer:
12. Do we need to meet any standards, such as SOC 2, ISO 27001 or HIPAA?
    - Answer:
13. Was there an incident or customer request that prompted this?
    - Answer:

## Practical

14. What's the GPU budget on the card, and who approves spending beyond it?
    - Answer:
15. Do I get my own login in the company's Lambda account, or should I create
    one?
    - Answer:
16. Can I test with our real code and models, or should I stick to public open
    models?
    - Answer:
