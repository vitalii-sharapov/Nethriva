#!/usr/bin/env python3
"""Run local native cursor ownership regression with ASan/UBSan, no network/clipboard.

Usage: test-native-bridge-lifecycle.py /absolute/trusted-native-build /absolute/new-output
All bridge sources are instrumented; linked third-party libraries are not.
"""
from pathlib import Path
import os
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit(__doc__)
workspace, output = map(lambda x: Path(x).absolute(), sys.argv[1:])
repo = Path(__file__).resolve().parent.parent
prefix = workspace/'prefix'
if not (prefix/'include/freerdp3/freerdp/freerdp.h').is_file():
    raise SystemExit('A trusted pinned native build prefix is required.')
output.mkdir(mode=0o700, parents=False, exist_ok=False)
command = ['/usr/bin/clang', '-fsanitize=address,undefined', '-g', '-O1', '-fno-objc-arc',
           '-fobjc-exceptions', '-I', str(prefix/'include/freerdp3'), '-I', str(prefix/'include/winpr3'),
           '-I', str(prefix/'include'), '-L', str(prefix/'lib'), '-Wl,-rpath,'+str(prefix/'lib'),
           str(repo/'scripts/test-native-bridge-lifecycle.m')]
command += [str(path) for path in sorted((repo/'Vendor/NethrivaRDPBridge').glob('*.m')) if path.name != 'MRDPView.m']
command += ['-lfreerdp-client3', '-lfreerdp3', '-lwinpr3', '-lssl', '-lcrypto']
for framework in ['Cocoa', 'Carbon', 'IOKit', 'Security', 'CoreVideo', 'CoreGraphics', 'CoreFoundation', 'ApplicationServices']:
    command += ['-framework', framework]
command += ['-o', str(output/'bridge-lifecycle')]
environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
with (output/'build.log').open('x') as log:
    subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
with (output/'test.log').open('x') as log:
    subprocess.run([str(output/'bridge-lifecycle')], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
print('PASS: native bridge cursor ownership, retained bitmap lifetime and bounded dimension regression under ASan/UBSan.')
