# Questions for the person who assigned the task

If there's only time for a few, ask the ★ ones first: those answers decide what
gets built. Fill in each answer as it comes back.

## What they want

1. ★ What should I hand in at the end: a working image, a written
   recommendation, a live demo, or a mix? How will it be judged?
   - Answer:
2. When is it due, and can we check in partway through?
   - Answer:
3. ★ Is this image for our own inference servers, or for something customers
   would run?
   - Answer:

## How we run inference today

4. Are we on Lambda now? If so, which images do we use (Lambda Stack, GPU Base,
   plain Ubuntu)? Should the solution also work on other providers or our own
   hardware?
   - Answer:
5. ★ Which inference engine do we use (vLLM, TensorRT-LLM/Triton, SGLang,
   something in-house)?
   - Answer:
6. Which GPUs do we serve on (H100, B200, A100, ...)?
   - Answer:
7. Do we serve our own model weights, open models like Llama or Qwen, or both?
   - Answer:
8. ★ Does one GPU serve many customers at the same time, or does each customer
   get their own?
   - Answer:
9. What sits in front of the GPU servers? Is there an API gateway that handles
   customer keys and HTTPS?
   - Answer:
10. How do machines get set up and updated today: Kubernetes, Terraform,
    scripts, by hand over SSH?
    - Answer:

## What worries them most

11. ★ What's the biggest concern: customer prompts leaking, model weights being
    stolen, servers being hijacked, or passing compliance and customer security
    reviews?
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
16. Can I test with our real inference code and models, or should I stick to
    public open models?
    - Answer:
