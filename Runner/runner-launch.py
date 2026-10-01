#!/usr/bin/env python3
"""Give the Mac app's owned XCTest child an isolated process group."""
import os
import sys
os.setsid()
os.execv('/bin/bash', ['/bin/bash', *sys.argv[1:]])
