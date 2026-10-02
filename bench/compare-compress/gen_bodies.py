# Writes the bodies the harness compresses. "bench-N" replicates
# nilo/bench/compress_bench.zig's body(count, m) byte for byte (std.json,
# compact); "arena-N" is HttpArena's json-comp body built from
# data/dataset.json the way the profile asks (first N items, total=price*qty*m).
import json, os
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bodies')
os.makedirs(out, exist_ok=True)
names = ["Alpha Widget","Beta Gadget","Gamma Gizmo","Delta Device","Epsilon Engine"]
cats = ["electronics","home","garden","toys","office"]
tagsets = [["fast","new"],["sale"],["popular","bulk","eco"]]
def bench(count, m):
    items = []
    for i in range(count):
        price = 100 + (i*37) % 900
        qty = 1 + (i*7) % 40
        items.append({"id":i+1,"name":names[i%5],"category":cats[i%5],"price":price,
            "quantity":qty,"active":i%3!=0,"tags":tagsets[i%3],
            "rating":{"score":10+(i*13)%40,"count":(i*53)%500},"total":price*qty*m})
    return json.dumps({"items":items,"count":count},separators=(',',':')).encode()
ds = json.load(open(os.path.expanduser('~/development/HttpArena/data/dataset.json')))
def arena(count, m, src=ds):
    items = []
    for it in src[:count]:
        d = dict(it); d["total"] = it["price"]*it["quantity"]*m
        items.append(d)
    return json.dumps({"items":items,"count":count},separators=(',',':')).encode()
bodies = {
  'bench-6': bench(6,5), 'bench-25': bench(25,4), 'bench-40': bench(40,8), 'bench-50': bench(50,6),
  'bench-400': bench(400,5), 'bench-6400': bench(6400,5), 'bench-24000': bench(24000,5),
  'arena-25': arena(25,4), 'arena-40': arena(40,8), 'arena-50': arena(50,6),
}
large = json.load(open(os.path.expanduser('~/development/HttpArena/data/dataset-large.json')))
bodies['arenalarge-all'] = arena(len(large), 5, large)
for k,v in bodies.items():
    open(f'{out}/{k}.json','wb').write(v)
    print(f'{k:16} {len(v):>9}')
