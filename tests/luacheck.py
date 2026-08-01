import sys, glob, os
import lupa
# Prefer a LuaJIT / 5.1 runtime: FS25 runs LuaJIT, so 5.1 syntax rules apply.
rt = None
for mod in ("luajit20","luajit21","lua51","lua52","lua53","lua54","lua55"):
    try:
        rt = getattr(lupa, mod).LuaRuntime(); name = mod; break
    except Exception: pass
if rt is None:
    rt = lupa.LuaRuntime(); name = "default"
print(f"# parser: {name} ({rt.lua_implementation} {rt.lua_version})\n")
check = rt.eval("function(s,n) local f,e = load(s,n); return {ok = f ~= nil, err = e} end")
root = r"C:\Users\tison\Desktop\FS25 MODS\FS25_TransportCompany"
bad = 0
files = sorted(glob.glob(os.path.join(root,"scripts","**","*.lua"), recursive=True))
for f in files:
    src = open(f, encoding="utf-8").read()
    r = check(src, "@"+os.path.basename(f))
    rel = os.path.relpath(f, root)
    if not r["ok"]:
        bad += 1; print(f"FAIL {rel}\n     {r['err']}")
    else:
        print(f"ok   {rel}")
print(f"\n{len(files)} files, {bad} syntax errors")
sys.exit(1 if bad else 0)
