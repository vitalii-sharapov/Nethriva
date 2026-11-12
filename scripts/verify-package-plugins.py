#!/usr/bin/env python3
"""Verify reviewed build-tool plugin source before noninteractive CI approval.

Only the pinned SwiftTerm build-info generator is approved. This does not change
Xcode's global fingerprint policy or disable the SwiftPM execution sandbox.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parent.parent

def verify(cache):
    lock=json.loads((ROOT/'scripts/swift-package-plugins.lock.json').read_text())
    resolved=json.loads((ROOT/'Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
    revisions={pin['identity']:pin['state']['revision'] for pin in resolved['pins']}
    approved=set()
    for plugin in lock['packages']:
        identity=plugin['identity'];package=cache/'checkouts'/plugin['checkout']
        if revisions.get(identity)!=plugin['revision']:
            raise ValueError('Build plugin needs review for the new package revision: '+identity)
        revision=subprocess.check_output(['/usr/bin/git','-C',str(package),'rev-parse','HEAD'],text=True).strip()
        if revision!=plugin['revision']:
            raise ValueError('Build plugin checkout differs from the reviewed revision')
        for relative,digest in plugin['filesSHA256'].items():
            path=package/relative
            if path.is_symlink() or not path.resolve(strict=True).is_relative_to(package.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
                raise ValueError('Reviewed build plugin source changed: '+relative)
            approved.add(path.resolve())
    for checkout in (cache/'checkouts').iterdir():
        for source in (checkout/'Plugins').rglob('*.swift'):
            if re.search(r':\s*BuildToolPlugin\b',source.read_text()) and source.resolve() not in approved:
                raise ValueError('An additional build-tool plugin requires review: '+checkout.name)
    print('PASS: immutable package revision and reviewed build-info plugin/source hashes verified; SwiftPM sandbox remains enabled.')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package-cache',type=Path,required=True);args=parser.parse_args()
    try:verify(args.package_cache.resolve(strict=True))
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as error:
        print('Build plugin verification failed: '+str(error),file=sys.stderr);return 1
    return 0
if __name__=='__main__':sys.exit(main())
