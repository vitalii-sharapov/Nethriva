#!/usr/bin/env python3
"""Check every managed dependency against official upstream before version builds.

Never installs or updates automatically. Outdated/unverifiable managed components fail.
Host Xcode is reported separately; --require-current-toolchain makes it mandatory.
Every invocation queries upstream; there is no stale-success/offline bypass.
"""
import argparse
import concurrent.futures
import functools
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import threading
import urllib.error
import xml.etree.ElementTree as ET
import time
import uuid
import urllib.parse
import urllib.request

API_LIMITED = threading.Event()
ROOT = Path(__file__).resolve().parent.parent
SEMVER = r'^v?(\d+)\.(\d+)\.(\d+)$'
NATIVE = {
 'FreeRDP': ('FreeRDP/FreeRDP','releases',SEMVER),
 'OpenSSL': ('openssl/openssl','releases',r'^openssl-(\d+)\.(\d+)\.(\d+)$'),
 'SDL3': ('libsdl-org/SDL','releases',r'^release-(\d+)\.(\d+)\.(\d+)$'),
 'SDL3_ttf': ('libsdl-org/SDL_ttf','releases',r'^release-(\d+)\.(\d+)\.(\d+)$'),
 'zlib': ('madler/zlib','releases',r'^v(\d+)\.(\d+)(?:\.(\d+))?$'),
 'json-c': ('json-c/json-c','releases',r'^json-c-(\d+)\.(\d+)-\d+$'),
 'uriparser': ('uriparser/uriparser','releases',r'^uriparser-(\d+)\.(\d+)\.(\d+)$'),
 'FreeType': ('freetype/freetype','tags',r'^VER-(\d+)-(\d+)-(\d+)$'),
 'FDK-AAC': ('mstorsjo/fdk-aac','tags',SEMVER),
 'OpenH264': ('cisco/openh264','releases',SEMVER),
 'Opus': ('xiph/opus','tags',r'^v(\d+)\.(\d+)(?:\.(\d+))?$'),
 'libusb': ('libusb/libusb','releases',SEMVER),
 'CMake': ('Kitware/CMake','releases',SEMVER),
 'pkgconf': ('pkgconf/pkgconf','tags',r'^pkgconf-(\d+)\.(\d+)\.(\d+)$'),
}
SCANNERS = {'gitleaks': 'gitleaks/gitleaks', 'osv-scanner': 'google/osv-scanner', 'actionlint': 'rhysd/actionlint'}

class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        before, after = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if after.scheme != 'https' or after.netloc.lower() != before.netloc.lower():
            raise ValueError('Cross-origin upstream redirect refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)

@functools.lru_cache(maxsize=128)
def fetch(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.hostname not in {
        'api.github.com', 'github.com', 'gitlab.freedesktop.org', 'developer.apple.com'}:
        raise ValueError('Unexpected upstream endpoint')
    headers = {'User-Agent': 'Nethriva-dependency-preflight', 'Accept': 'application/json', 'Cache-Control': 'no-cache'}
    # Only the caller-provided CI token is used, never a credential store or CLI login.
    token = os.environ.get('GITHUB_TOKEN')
    if token and parsed.hostname == 'api.github.com':
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.build_opener(SafeRedirect()).open(request, timeout=30) as response:
        data = response.read(4*1024*1024+1)
    if len(data) > 4*1024*1024:
        raise ValueError('Upstream metadata exceeds review budget')
    return data

def get_json(url):
    return json.loads(fetch(url))

def version_tuple(value):
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', value):
        raise ValueError('Invalid pinned version')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,)*(3-len(parts))

def select_latest(records, pattern, kind):
    if not isinstance(records, list):
        raise ValueError('Expected upstream version list')
    candidates = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError('Malformed upstream version entry')
        if kind == 'releases' and (record.get('draft') or record.get('prerelease')):
            continue
        tag = record.get('tag_name') if kind == 'releases' else record.get('name')
        match = re.fullmatch(pattern, tag or '')
        if not match:
            continue
        groups = match.groups()
        numeric = tuple(int(part or 0) for part in groups)
        numeric += (0,)*(3-len(numeric))
        candidates.append((numeric, tag, record))
    if not candidates:
        raise ValueError('No matching stable upstream version; review required')
    return max(candidates, key=lambda item: (item[0], item[1]))

def github_versions(repo, kind):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Invalid upstream repository')
    if API_LIMITED.is_set():return github_atom_versions(repo,kind)
    try:return get_json('https://api.github.com/repos/'+repo+'/'+kind+'?per_page=100')
    except urllib.error.HTTPError as error:
        if error.code not in (403,429):raise
        API_LIMITED.set()
        return github_atom_versions(repo,kind)

def public_git_tag(repo, tag):
    """Read a public immutable ref without API quotas or user credentials/config."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not re.fullmatch(r'[A-Za-z0-9_.-]+', tag):
        raise ValueError('Unexpected public tag lookup')
    environment={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','GIT_CONFIG_NOSYSTEM':'1',
                 'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_COUNT':'0','GIT_TERMINAL_PROMPT':'0',
                 'GIT_ASKPASS':'/usr/bin/false','SSH_ASKPASS':'/usr/bin/false',
                 'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')}
    ref='refs/tags/'+tag
    with tempfile.TemporaryDirectory(prefix='Nethriva-public-ref-') as directory:
        process=subprocess.run(['/usr/bin/git','-c','credential.helper=','ls-remote',
                                'https://github.com/'+repo+'.git',ref,ref+'^{}'],
                               cwd=directory,env=environment,stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL,timeout=30,check=True)
    return parse_public_refs(process.stdout,ref)

def parse_public_refs(raw, ref):
    if len(raw)>65536:raise ValueError('Public ref response exceeds budget')
    refs={}
    for line in raw.decode('ascii').splitlines():
        fields=line.split()
        if len(fields)!=2 or not re.fullmatch(r'[a-f0-9]{40}',fields[0]) or fields[1] not in {ref,ref+'^{}'}:
            raise ValueError('Unexpected public ref response')
        if fields[1] in refs and refs[fields[1]]!=fields[0]:raise ValueError('Conflicting public refs')
        refs[fields[1]]=fields[0]
    digest=refs.get(ref+'^{}',refs.get(ref))
    if not digest:raise ValueError('Public tag revision unavailable')
    return digest

def github_atom_versions(repo,kind):
    raw=fetch('https://github.com/'+repo+'/'+kind+'.atom')
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():raise ValueError('Unsafe upstream XML')
    tree=ET.fromstring(raw)
    ns={'a':'http://www.w3.org/2005/Atom'};records=[]
    prefix='/'+repo.lower()+'/releases/tag/'
    for entry in tree.findall('a:entry',ns):
        link=entry.find('a:link',ns)
        if link is None:continue
        url=urllib.parse.urlsplit(link.get('href',''))
        if url.scheme!='https' or url.hostname!='github.com' or not url.path.lower().startswith(prefix):
            raise ValueError('Unexpected official feed entry')
        tag=urllib.parse.unquote(url.path[len(prefix):])
        records.append({'tag_name' if kind=='releases' else 'name':tag,'_transport':'fresh-official-atom'})
    if not records:raise ValueError('Official upstream feed is empty')
    return records

def action_commit(repo, tag):
    if API_LIMITED.is_set():return public_git_tag(repo,tag)
    try:return action_commit_api(repo,tag)
    except urllib.error.HTTPError as error:
        if error.code not in (403,429):raise
        API_LIMITED.set();return public_git_tag(repo,tag)

def action_commit_api(repo, tag):
    value = get_json('https://api.github.com/repos/'+repo+'/git/ref/tags/'+urllib.parse.quote(tag, safe=''))['object']
    for _ in range(4):
        digest = value['sha']
        if not re.fullmatch(r'[a-f0-9]{40}', digest):
            raise ValueError('Invalid upstream action revision')
        if value['type'] == 'commit':
            return digest
        if value['type'] != 'tag':
            break
        value = get_json('https://api.github.com/repos/'+repo+'/git/tags/'+digest)['object']
    raise ValueError('Action tag did not resolve to a commit')

def inventory(root, scope):
    native = json.loads((root/'scripts/native-runtime.lock.json').read_text())
    items = []
    for pin in native['components'] + native['tooling']:
        if pin['name'] not in NATIVE:
            raise ValueError('Unmonitored native component: '+pin['name'])
        repo, kind, pattern = NATIVE[pin['name']]
        items.append(dict(name=pin['name'], version=pin['version'], repo=repo, kind=kind, pattern=pattern))
    if scope == 'native':
        return items
    packages = json.loads((root/'Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
    for pin in packages['pins']:
        location = urllib.parse.urlsplit(pin['location'])
        if location.scheme != 'https' or location.hostname != 'github.com':
            raise ValueError('Unmonitored Swift package source')
        repo = location.path.strip('/').removesuffix('.git')
        state = pin['state']
        items.append(dict(name=pin['identity'], version=state['version'], revision=state['revision'], repo=repo, kind='tags', pattern=SEMVER))
    consoles = json.loads((root/'Nethriva/Resources/Consoles/dependencies.lock.json').read_text())
    for pin in consoles['components']:
        if pin['name'] == 'noVNC':
            items.append(dict(name='noVNC', version=pin['version'], revision=pin['revision'], repo='novnc/noVNC', kind='tags', pattern=SEMVER))
        elif pin['name'] == 'SPICE HTML5':
            items.append(dict(name=pin['name'], revision=pin['revision'], kind='gitlab-head'))
        else:
            raise ValueError('Unmonitored console component')
    security = json.loads((root/'scripts/security-tools.lock.json').read_text())
    grouped = {}
    for pin in security['tools']:
        grouped.setdefault(pin['name'], set()).add(pin['version'])
    for name, versions in grouped.items():
        if name not in SCANNERS or len(versions) != 1:
            raise ValueError('Unmonitored or inconsistent security-tool pin: '+name)
        items.append(dict(name=name, version=next(iter(versions)), repo=SCANNERS[name], kind='releases', pattern=SEMVER))
    actions = {}
    for workflow in sorted((root/'.github/workflows').glob('*.yml')):
        for match in re.finditer(r'^\s*-?\s*uses:\s*([\w.-]+/[\w.-]+)(?:/[\w./-]+)?@([a-zA-Z0-9_.-]+)', workflow.read_text(), re.M):
            repo, revision = match.groups()
            if not re.fullmatch(r'[a-f0-9]{40}', revision):
                raise ValueError('CI action must use an immutable revision: '+repo)
            actions.setdefault(repo, set()).add(revision)
    for repo, revisions in actions.items():
        if len(revisions) != 1:
            raise ValueError('Inconsistent workflow action revisions: '+repo)
        items.append(dict(name='CI '+repo, revision=next(iter(revisions)), repo=repo, kind='action', pattern=SEMVER))
    return items

def check_item(pin):
    result = dict(name=pin['name'], pinned=pin.get('version', pin.get('revision')), status='unverified')
    try:
        if pin['kind'] == 'gitlab-head':
            records = get_json('https://gitlab.freedesktop.org/api/v4/projects/spice%2Fspice-html5/repository/commits?per_page=1')
            newest = records[0]['id']
            if not re.fullmatch(r'[a-f0-9]{40}', newest):
                raise ValueError('Invalid SPICE upstream revision')
            result.update(latest=newest, status='current' if newest == pin['revision'] else 'outdated')
            return result
        kind = 'releases' if pin['kind'] == 'action' else pin['kind']
        numeric, tag, record = select_latest(github_versions(pin['repo'], kind), pin['pattern'], kind)
        result['latest'] = tag
        result['lookupTransport'] = record.get('_transport','github-api')
        result['source'] = 'https://github.com/'+pin['repo']+'/releases/tag/'+tag if kind == 'releases' else 'https://github.com/'+pin['repo']+'/tree/'+tag
        if pin['kind'] == 'action':
            result['latestRevision'] = action_commit(pin['repo'], tag)
            current = result['latestRevision'] == pin['revision']
        else:
            current = version_tuple(pin['version']) == numeric
            if current and pin.get('revision'):
                result['latestRevision'] = record.get('commit', {}).get('sha') or public_git_tag(pin['repo'],tag)
                current = result['latestRevision'] == pin['revision']
        result['status'] = 'current' if current else 'outdated'
    except Exception as error:
        result['error'] = type(error).__name__+': '+str(error)
    return result

def verify_console_sources(root, directory=None):
    directory = Path(directory) if directory is not None else root/'Nethriva/Resources/Consoles'
    lock = json.loads((directory/'dependencies.lock.json').read_text())
    expected = {}
    for component in lock['components']:
        expected.update(component['filesSHA256'])
    actual = set()
    for name in ['noVNC', 'spice']:
        for path in (directory/name).rglob('*'):
            if path.is_symlink():
                raise ValueError('Unexpected console source symlink')
            if path.is_file():
                actual.add(path.relative_to(directory).as_posix())
    if actual != set(expected):
        raise ValueError('Console source file set differs from provenance')
    for relative, digest in expected.items():
        path = directory/relative
        if not path.resolve(strict=True).is_relative_to(directory.resolve()) or not re.fullmatch(r'[a-f0-9]{64}', digest):
            raise ValueError('Invalid console provenance entry')
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('Console source hash mismatch: '+relative)

class XcodeTable(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_cell=False; self.cell=''; self.versions=[]
    def handle_starttag(self, tag, attrs):
        if tag == 'td': self.in_cell=True; self.cell=''
    def handle_data(self, data):
        if self.in_cell: self.cell+=data
    def handle_endtag(self, tag):
        if tag == 'td' and self.in_cell:
            text=' '.join(self.cell.split())
            match=re.fullmatch(r'Xcode\s+(\d+(?:\.\d+)*)', text)
            if match:self.versions.append(match.group(1))
            self.in_cell=False

def check_toolchain():
    result = dict(name='Xcode', status='unverified')
    try:
        parser = XcodeTable(); parser.feed(fetch('https://developer.apple.com/xcode/system-requirements').decode())
        if not parser.versions: raise ValueError('Stable Xcode release could not be determined')
        newest = max(parser.versions, key=lambda x:version_tuple(x if '.' in x else x+'.0'))
        environment = dict(os.environ)
        environment.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
        output = subprocess.check_output(['/usr/bin/xcodebuild','-version'], env=environment, text=True, stderr=subprocess.STDOUT)
        installed = re.search(r'^Xcode\s+(\d+(?:\.\d+)*)', output, re.M).group(1)
        result.update(pinned=installed, latest=newest,
                      status='current' if version_tuple(installed if '.' in installed else installed+'.0') >= version_tuple(newest if '.' in newest else newest+'.0') else 'outdated')
    except Exception as error:
        result['error']=type(error).__name__+': '+str(error)
    return result

def input_hashes(root):
    paths=[root/'scripts/native-runtime.lock.json',root/'scripts/security-tools.lock.json',
           root/'scripts/check-dependency-updates.py',root/'scripts/swift-package-plugins.lock.json',
           root/'scripts/dependency-preflight-inputs.xcfilelist',
           root/'Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
           root/'Nethriva/Resources/Consoles/dependencies.lock.json']
    paths+=sorted((root/'.github/workflows').glob('*.yml'))
    return {path.relative_to(root).as_posix():hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}

def write_report(path, report):
    path=Path(path).absolute(); path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary=tempfile.mkstemp(prefix='.dependency-report-', dir=path.parent)
    try:
        with os.fdopen(descriptor,'w') as stream:json.dump(report,stream,indent=2);stream.write('\n')
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope',choices=['all','native'],default='all')
    parser.add_argument('--report',type=Path)
    parser.add_argument('--require-current-toolchain',action='store_true')
    parser.add_argument('--verify-console-directory',type=Path,help='Verify only an exact built/extracted console bundle, without network.')
    args=parser.parse_args()
    if args.verify_console_directory:
        try:verify_console_sources(ROOT,args.verify_console_directory)
        except (ValueError,OSError,KeyError) as error:
            print('Console integrity failed: '+str(error),file=sys.stderr);return 1
        print('PASS: exact built console sources and provenance match.');return 0
    if args.report:write_report(args.report,dict(schema=1,managedCurrent=False,toolchainCurrent=False,status='checking'))
    try:
        pins=inventory(ROOT,args.scope)
        if args.scope == 'all':verify_console_sources(ROOT)
    except Exception as error:
        print('Dependency preflight failed: '+str(error),file=sys.stderr);return 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:results=list(pool.map(check_item,pins))
    toolchain=check_toolchain() if platform.system() == 'Darwin' else None
    current=all(item['status']=='current' for item in results)
    tool_current=toolchain is not None and toolchain['status']=='current'
    report=dict(schema=1, scope=args.scope, checkedAt=time.time(), nonce=uuid.uuid4().hex,
                inputHashes=input_hashes(ROOT), managedCurrent=current, toolchainCurrent=tool_current, components=results, toolchain=toolchain)
    if args.report:write_report(args.report,report)
    for item in results+([toolchain] if toolchain else []):
        print(item['status'].upper()+': '+item['name']+' — '+str(item.get('pinned','unknown'))+' → '+str(item.get('latest','unverified')))
        if item.get('error'):print('  '+item['error'])
    if not current or (args.require_current_toolchain and not tool_current):
        print('Build blocked: update or verify the flagged components before creating a new version.',file=sys.stderr);return 1
    if not tool_current and toolchain:print('Managed components are current; Xcode update/verification remains outstanding.')
    elif toolchain:print('PASS: managed components and selected build toolchain are current.')
    else:print('PASS: managed components are current; Apple toolchain is not inspected on this host.')
    return 0

if __name__ == '__main__':sys.exit(main())
