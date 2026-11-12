#!/usr/bin/env python3
"""Regenerate exact sandbox input declarations after reviewing a dependency update."""
import argparse
import json
from pathlib import Path
import sys

root=Path(__file__).resolve().parent.parent
base=root/'Nethriva/Resources/Consoles'
lock=json.loads((base/'dependencies.lock.json').read_text())
files=['scripts/check-dependency-updates.py','scripts/verify-dependency-preflight.py',
       'scripts/native-runtime.lock.json','scripts/security-tools.lock.json',
       'scripts/swift-package-plugins.lock.json','scripts/dependency-preflight-inputs.xcfilelist',
       'Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
       'Nethriva/Resources/Consoles/dependencies.lock.json']
files += [path.relative_to(root).as_posix() for path in (root/'.github/workflows').glob('*.yml')]
for component in lock['components']:
    files += ['Nethriva/Resources/Consoles/'+name for name in component['filesSHA256']]
for relative in files:
    if not (root/relative).resolve(strict=True).is_relative_to(root):
        raise SystemExit('Declared input escaped the source root')
text='\n'.join('$(SRCROOT)/'+name for name in sorted(set(files)))+'\n'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
path=root/'scripts/dependency-preflight-inputs.xcfilelist'
if args.check:
    if path.read_text()!=text:raise SystemExit('Dependency input list is stale; regenerate and review it.')
    print('PASS: sandbox input list covers current pins, workflows and every vendored console file.')
else:
    path.write_text(text)
    print('Regenerated dependency input list; review its diff before building.')
