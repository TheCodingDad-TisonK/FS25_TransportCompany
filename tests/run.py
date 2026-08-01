"""Run the Transport Company suites against the real mod source.

Needs lupa (pip install lupa). Stubs the engine surface and loads the
actual Lua files, so these exercise shipped code rather than a copy.
"""
import os, sys, lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.dirname(os.path.abspath(__file__))
rt = lupa.luajit20.LuaRuntime(unpack_returned_tuples=True)

total = 0
for name in ("simtest", "simtest2", "simtest3", "simtest4"):
    src = open(os.path.join(HERE, name + ".lua"), encoding="utf-8").read()
    src = src.replace("os.exit(fail == 0 and 0 or 1)", "return fail")
    fails = rt.eval("function(s,n) return load(s,n) end")(src, "@" + name)(ROOT.replace("\\", "/"))
    total += fails or 0

print("\nTOTAL FAILURES:", total)
sys.exit(1 if total else 0)
