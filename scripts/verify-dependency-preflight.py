#!/usr/bin/env python3
"""Offline, sandboxed build-phase enforcement of a fresh upstream-check receipt."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('dependency_check',Path(__file__).with_name('check-dependency-updates.py'))
check=importlib.util.module_from_spec(spec);spec.loader.exec_module(check)

def verify(receipt, consumed):
    data=json.loads(Path(receipt).read_text())
    if data.get('schema')!=1 or data.get('scope')!='all' or data.get('managedCurrent') is not True or data.get('toolchainCurrent') is not True:
        raise ValueError('Fresh upstream check did not verify all components and Xcode')
    age=time.time()-data.get('checkedAt',0)
    if not -5<=age<=900:
        raise ValueError('Upstream check is stale; run a fresh version build')
    nonce=data.get('nonce','')
    if not re.fullmatch(r'[a-f0-9]{32}',nonce):raise ValueError('Invalid preflight receipt')
    if data.get('inputHashes')!=check.input_hashes(check.ROOT):
        raise ValueError('Dependency inputs changed after the upstream check')
    expected={item['name'] for item in check.inventory(check.ROOT,'all')}
    records=data.get('components',[])
    if len(records)!=len(expected) or {item.get('name') for item in records}!=expected or any(item.get('status')!='current' for item in records):
        raise ValueError('Incomplete or failed dependency-check coverage')
    check.verify_console_sources(check.ROOT)
    consumed=Path(consumed);consumed.parent.mkdir(parents=True,exist_ok=True)
    descriptor=os.open(consumed,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(descriptor,fcntl.LOCK_EX)
        raw=os.read(descriptor,1024*1024+1)
        if len(raw)>1024*1024:raise ValueError('Preflight receipt ledger exceeds budget')
        ledger=json.loads(raw) if raw else []
        ledger=[entry for entry in ledger if time.time()-entry['time']<=900]
        if any(entry['nonce']==nonce for entry in ledger):raise ValueError('Preflight receipt was already consumed by another build')
        ledger.append(dict(nonce=nonce,time=time.time()))
        encoded=json.dumps(ledger).encode()
        os.lseek(descriptor,0,os.SEEK_SET);os.ftruncate(descriptor,0);os.write(descriptor,encoded);os.fsync(descriptor)
    finally:os.close(descriptor)
    print('PASS: fresh current-component/toolchain receipt matches all pins and is consumed once for this build.')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('receipt',type=Path);parser.add_argument('consumed_directory',type=Path);args=parser.parse_args()
    try:verify(args.receipt,args.consumed_directory)
    except (ValueError,OSError,KeyError,TypeError) as error:
        print('Version build blocked: '+str(error),file=sys.stderr);return 1
    return 0
if __name__=='__main__':sys.exit(main())
