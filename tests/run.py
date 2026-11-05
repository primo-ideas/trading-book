"""Runs the Lua test suite on Lua 5.1, the version WoW uses.

Requires lupa (pip install lupa). Run from anywhere: python tests/run.py
"""
import os
import sys

import lupa.lua51 as lua51


def main():
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    failed = runtime.execute('return dofile("tests/tests.lua")')
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
