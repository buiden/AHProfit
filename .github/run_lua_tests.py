"""Syntax-check every addon/test file and run the Lua test files in Lua 5.1 (lupa)."""
import pathlib
import subprocess
import sys

import lupa.lua51 as lupa

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ["test/harness.lua", "test/extra_test.lua", "test/sync_test.lua", "test/ui_test.lua", "test/ledger_test.lua"]

if len(sys.argv) == 2:
    # One test per process: the tests call os.exit with their result.
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute("arg = {[0] = %r}" % sys.argv[1])
    L.execute("dofile(%r)" % sys.argv[1])
    sys.exit(0)

L = lupa.LuaRuntime()
bad = 0
for f in sorted(ROOT.glob("AHProfit/*.lua")) + sorted(ROOT.glob("test/*.lua")):
    ok, err = L.eval("function(s, n) local f, e = loadstring(s, n) return f ~= nil, e end")(f.read_text(encoding="utf-8"), "@" + f.relative_to(ROOT).as_posix())
    if not ok:
        print("SYNTAX", err)
        bad += 1
print("syntax:", "OK" if not bad else "%d file(s) failed" % bad)
for t in TESTS:
    print("==", t, flush=True)
    rc = subprocess.run([sys.executable, "-I", "-B", __file__, t], cwd=ROOT).returncode
    if rc:
        print("FAILED", t, "exit", rc)
        bad += 1
sys.exit(1 if bad else 0)
