#!/usr/bin/env python3
"""Install pinned scanners into an explicit disposable/private tool directory."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import stat
import tarfile
import urllib.parse
import urllib.request

LIMIT = 128 * 1024 * 1024

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--tool', action='append', choices=['gitleaks', 'osv-scanner', 'actionlint'])
    args = parser.parse_args()
    target = args.directory.absolute()
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = target.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise SystemExit('Refusing an unsafe security-tool directory.')
    system = platform.system().lower()
    machine = {'aarch64':'arm64', 'amd64':'x86_64'}.get(platform.machine().lower(), platform.machine().lower())
    lock = json.loads(Path(__file__).with_name('security-tools.lock.json').read_text())
    requested = set(args.tool or ['gitleaks', 'osv-scanner', 'actionlint'])
    tools = [x for x in lock['tools'] if x['platform'] == system + '-' + machine and x['name'] in requested]
    if {x['name'] for x in tools} != requested:
        raise SystemExit('No pinned security tools for this platform.')
    for tool in tools:
        source = urllib.parse.urlsplit(tool['url'])
        if source.scheme != 'https' or source.hostname != 'github.com' or source.username or source.password:
            raise SystemExit('Tool source is not an approved HTTPS release.')
        request = urllib.request.Request(tool['url'], headers={'User-Agent':'Nethriva-security-tool-installer'})
        with urllib.request.urlopen(request, timeout=90) as response:
            if urllib.parse.urlsplit(response.url).scheme != 'https':
                raise SystemExit('Insecure tool-download redirect refused.')
            data = response.read(LIMIT + 1)
        if len(data) > LIMIT or hashlib.sha256(data).hexdigest() != tool['sha256']:
            raise SystemExit('Security-tool download size/checksum verification failed.')
        executable = data
        if tool['archive'] == 'tar.gz':
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                members = [m for m in archive.getmembers() if m.name in [tool['name'], './'+tool['name']]]
                if len(members) != 1 or not members[0].isfile() or members[0].size > LIMIT:
                    raise SystemExit('Unexpected security-tool archive layout.')
                executable = archive.extractfile(members[0]).read(LIMIT + 1)
        if len(executable) > LIMIT:
            raise SystemExit('Oversized security-tool executable.')
        destination = target / tool['name']
        # Exclusive creation also refuses links and accidental replacement of an existing tool.
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(executable)
        print(tool['name'] + ' ' + tool['version'] + ': verified and installed')

if __name__ == '__main__':
    main()
