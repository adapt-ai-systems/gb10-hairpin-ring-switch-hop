import json,sys,statistics as st
d="ab-runs/"+sys.argv[1]; m=st.median
w=lambda f:json.load(open(f"{d}/{f}"))["results"][0]
r={}
for t in ("prose","code","structured"):
    r[t+"_c1"]=m(w(f"{t}-c1-{i}.json")["medianDecodeTps"] for i in (1,2,3))
    r[t+"_c4"]=m(w(f"{t}-c4-{i}.json")["aggregateDecodeTps"] for i in (1,2,3))
    r[t+"_fail"]=sum(w(f"{t}-c{c}-{i}.json")["streamsFailed"] for c in (1,4) for i in (1,2,3))
p=[{x["targetTokens"]:x for x in json.load(open(f"{d}/prefill-{i}.json"))["results"]} for i in (1,2,3)]
for n in (8192,32768): r[f"fill{n}"]=m(q[n]["prefillTps"] for q in p)
rt=[json.loads(l) for l in open(f"{d}/realprefill.jsonl") if l.startswith("{")]
for n in (8192,32768): r[f"real{n}"]=m(x["prefill_tps"] for x in rt if x["target"]==n)
print(json.dumps({k:round(v,1) for k,v in r.items()}))
