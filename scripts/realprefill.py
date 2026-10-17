"""Real-text cold prefill: docs + source code, unique salt prefix per request (no prefix-cache hits).
usage: python3 -I realprefill.py <base_url> <corpus> <approx_tokens,...> [reps=3]
TTFT = time to first streamed content/reasoning byte; tok = usage.prompt_tokens. Thinking off, max_tokens 1."""
import json, sys, time, uuid, urllib.request
base, corpus_path, sizes = sys.argv[1], sys.argv[2], [int(x) for x in sys.argv[3].split(",")]
reps = int(sys.argv[4]) if len(sys.argv) > 4 else 3
corpus = open(corpus_path, encoding="utf-8", errors="ignore").read()
model = json.load(urllib.request.urlopen(base + "/v1/models"))["data"][0]["id"]
def one(n):
    salt = f"[run {uuid.uuid4()}]\n"
    text = salt + corpus[: int(n * 3.3)] + "\n\nSay OK."
    body = {"model": model, "messages": [{"role": "user", "content": text}], "max_tokens": 1,
            "temperature": 0, "stream": True, "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"thinking": False}}
    req = urllib.request.Request(base + "/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.perf_counter(); ttft = None; ptok = None
    with urllib.request.urlopen(req, timeout=3600) as r:
        for line in r:
            line = line.strip()
            if not line.startswith(b"data:") or line == b"data: [DONE]": continue
            d = json.loads(line[5:])
            if ttft is None and d.get("choices"): ttft = time.perf_counter() - t0
            if d.get("usage"): ptok = d["usage"]["prompt_tokens"]
    return ptok, ttft
for n in sizes:
    for i in range(reps):
        ptok, ttft = one(n)
        print(json.dumps({"target": n, "rep": i + 1, "prompt_tokens": ptok, "ttft_s": round(ttft, 3), "prefill_tps": round(ptok / ttft, 1)}), flush=True)
