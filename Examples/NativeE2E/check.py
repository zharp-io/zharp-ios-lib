"""Checks what the stand-in endpoint received after a native crash and the relaunch that sent it.

  python3 check.py <bodies dir> <dSYM DWARF file> <expected type> <expected message part> <function> <file>

Finds the crash report (its stack text, in the OTLP body), takes the NativeE2E frames
("N  NativeE2E  0x<address> 0x<load> + <offset>"), and symbolicates them with atos and the build's
dSYM, as the backend does: the expected function must be there, with its file and line.
"""
import glob
import re
import subprocess
import sys

bodies, dwarf, want_type, want_message, want_function, want_file = sys.argv[1:7]
text = ""
for path in sorted(glob.glob(bodies + "/*")):
    data = open(path, "rb").read().decode("latin-1")
    if want_type in data:
        text = data
        break
if not text:
    sys.exit(f"::error::no report with {want_type} was sent")
print(f"report with {want_type} found")
if want_message not in text:
    sys.exit(f"::error::the message ({want_message}) is missing")
print(f"message found: {want_message}")

frames = re.findall(r"^\d+\s+NativeE2E\s+0x([0-9a-f]{16}) 0x([0-9a-f]+) \+ \d+", text, re.M)
if not frames:
    sys.exit("::error::no NativeE2E frames in the report")
uuids = subprocess.run(["dwarfdump", "--uuid", dwarf], capture_output=True, text=True).stdout
print(uuids.strip())
# The dSYM is universal (the simulator build has x86_64 and arm64): the slice that ran is the one
# whose UUID the report names.
found = [(u, a) for u, a in re.findall(r"UUID: ([0-9A-F-]+) \((\w+)\)", uuids) if u.lower() in text.lower()]
if not found:
    sys.exit("::error::the report's binary images don't name any of the dSYM's UUIDs")
uuid, arch = found[0]
print(f"binary image UUID matches the dSYM's {arch} slice: {uuid}")
lines = []
for index, (address, load) in enumerate(frames):
    # Callers' frames are return addresses: look up the call instruction (one byte back), as the backend does.
    lookup = int(address, 16) - (1 if index else 0)
    out = subprocess.run(["atos", "-arch", arch, "-o", dwarf, "-l", "0x" + load, hex(lookup)], capture_output=True, text=True).stdout.strip()
    lines.append(out)
    print("  0x%s -> %s" % (address, out))
if "zharpTerminate" in lines[0] or "abort" in lines[0]:
    sys.exit("::error::the stack starts in the crash handling, not where the exception was thrown")
# The throw site itself can read line 0 in an optimized build (clang gives the call to
# __cxa_throw no line), so the function and file are what's required there; some frame of the
# file must still have its line.
if not any(want_function in l and want_file in l for l in lines) or not any(re.search(re.escape(want_file) + r":[1-9]", l) for l in lines):
    sys.exit(f"::error::{want_function} in {want_file} not among the symbolicated frames")
print(f"symbolicated: {want_function} ({want_file}:line)")
