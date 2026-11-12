#!/usr/bin/env python3
"""Run bounded production GFX regression with ASan/UBSan against a trusted native build.

Usage: test-native-gfx-budget.py /absolute/native-build-workspace /absolute/new-output
The workspace must contain the pinned, patched sources, build and prefix directories.
No network, application launch or remote endpoint is used; allocation is capped at 512 MiB.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit(__doc__)
workspace, output = map(lambda value: Path(value).absolute(), sys.argv[1:])
repo = Path(__file__).resolve().parent.parent
lock = json.loads((repo / 'scripts/native-runtime.lock.json').read_text())
component = next(item for item in lock['components'] if item['name'] == 'FreeRDP')
source = workspace / 'sources' / component['sourceDirectory'] / 'libfreerdp/gdi/gfx.c'
build = workspace / 'build' / component['sourceDirectory']
prefix = workspace / 'prefix'
if not source.is_file() or not (prefix / 'lib/libfreerdp3.dylib').is_file():
    raise SystemExit('Trusted pinned native build workspace is required.')
output.mkdir(mode=0o700, parents=False, exist_ok=False)
command = ['/usr/bin/clang', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
           '-g', '-O1', '-std=gnu11', '-D_DARWIN_C_SOURCE', '-DWITH_FREERDP_DEPRECATED',
           '-DGFX_REVIEW_SOURCE="' + str(source) + '"']
for include in [prefix/'include/freerdp3', prefix/'include/winpr3', prefix/'include', build/'include', build]:
    command += ['-I', str(include)]
command += ['-L', str(prefix/'lib'), '-Wl,-dead_strip', '-Wl,-rpath,'+str(prefix/'lib'),
            '-lfreerdp3', '-lwinpr3', '-lcrypto', str(repo/'scripts/test-native-gfx-budget.c'),
            '-o', str(output/'gfx-budget')]
environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
with (output/'build.log').open('x') as log:
    subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
with (output/'test.log').open('x') as log:
    subprocess.run([str(output/'gfx-budget')], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
print('PASS: bounded production GFX unit regression under ASan/UBSan; allocator path only, not full-library sanitizer coverage.')
