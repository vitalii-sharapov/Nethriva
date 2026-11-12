#!/usr/bin/env python3
"""Rebuild the arm64 RDP runtime from pinned sources into a new private temporary directory.

Does not install an application, modify saved data, replace source resources, or publish.
Requires full Xcode, Python 3.9+, network access and ~3 GiB free disk space.
After validation, a maintainer may explicitly copy the staged runtime into app resources.
"""
import sys,argparse,concurrent.futures,hashlib,json,os,re,shutil,stat,subprocess,tarfile,tempfile,urllib.request,urllib.parse,zipfile,datetime,uuid
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-dir',type=Path,help='New empty private build directory (default: private temporary directory).')
args=parser.parse_args()
repo=Path(__file__).resolve().parent.parent
lock_path=Path(__file__).with_name('native-runtime.lock.json')
lock_bytes=lock_path.read_bytes();lock=json.loads(lock_bytes)
if lock.get('schema')!=1:raise SystemExit('Unsupported native source lock schema')
if args.work_dir:
    root=args.work_dir.absolute()
    root.mkdir(mode=0o700,parents=False,exist_ok=False)
else:root=Path(tempfile.mkdtemp(prefix='Nethriva-native-',dir='/private/tmp'))
if root.is_symlink() or root.stat().st_uid!=os.getuid() or stat.S_IMODE(root.stat().st_mode)!=0o700:raise SystemExit('Build directory must be owned, private and not a symlink')
for directory in ['downloads','sources','tools','logs','prefix']: (root/directory).mkdir(mode=0o700)
subprocess.check_call([sys.executable,str(repo/'scripts/check-dependency-updates.py'),'--scope','native','--require-current-toolchain','--report',str(root/'upstream-preflight.json')])
(root/'native-runtime.lock.json').write_bytes(lock_bytes)

def safe_path(path,base):
    if not path.resolve().is_relative_to(base.resolve()):raise ValueError('Archive path escapes extraction root')

def fetch(item):
    url=item['url'];parts=urllib.parse.urlsplit(url)
    if parts.scheme!='https' or parts.username or parts.password:raise ValueError('Source URL must be HTTPS without embedded credentials')
    filename=item.get('filename') or parts.path.rsplit('/',1)[-1]
    if '/' in filename or filename in ['','.', '..']:raise ValueError('Unsafe download filename')
    destination=root/'downloads'/filename
    with urllib.request.urlopen(url,timeout=120) as response:
        final=urllib.parse.urlsplit(response.url)
        if final.scheme!='https' or final.username or final.password:raise ValueError('Insecure source redirect')
        data=response.read(256*1024*1024+1)
    if len(data)>256*1024*1024 or hashlib.sha256(data).hexdigest()!=item['sha256']:raise ValueError('Source SHA-256 mismatch: '+item['name'])
    destination.write_bytes(data)
    if filename.endswith('.whl'):
        base=root/'tools'
        with zipfile.ZipFile(destination) as archive:
            for name in archive.namelist():safe_path(base/name,base)
            archive.extractall(base)
        for tool in (base/'cmake/data/bin').iterdir():tool.chmod(0o755)
    else:
        base=root/('tools' if item['name']=='CMake' else 'sources')
        with tarfile.open(destination) as archive:
            for member in archive.getmembers():
                target=base/member.name;safe_path(target,base)
                if member.issym():safe_path(target.parent/member.linkname,base)
                if member.islnk():safe_path(base/member.linkname,base)
                if member.isdev() or member.isfifo():raise ValueError('Special file in source archive')
            archive.extractall(base)
    print('Verified source',item['name'],item['version'],flush=True)

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for result in pool.map(fetch,lock['components']+lock['tooling']):pass
prefix=root/'prefix';cmake=root/'tools'/next(item['binaryPath'] for item in lock['tooling'] if item['name']=='CMake')
developer=os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
env=os.environ.copy();env.update(DEVELOPER_DIR=developer,MACOSX_DEPLOYMENT_TARGET='14.0',PKG_CONFIG_PATH=str(prefix/'lib/pkgconfig'))
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
clang=subprocess.check_output(['/usr/bin/xcrun','--find','clang'],env=env,text=True).strip()
env['SDKROOT']=sdk;env['PATH']=str(prefix/'bin')+':'+env['PATH'];env['lt_cv_sys_max_cmd_len']='65536'
flags='-O2 -arch arm64 -mcpu=apple-m1 -fstack-protector-strong -mmacosx-version-min=14.0 -isysroot '+sdk
env.update(CFLAGS=flags,CXXFLAGS=flags,LDFLAGS='-arch arm64 -mmacosx-version-min=14.0 -isysroot '+sdk)
common=['-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0','-DCMAKE_OSX_SYSROOT='+sdk,
        '-DCMAKE_INSTALL_PREFIX='+str(prefix),'-DCMAKE_INSTALL_LIBDIR=lib','-DCMAKE_INSTALL_NAME_DIR=@rpath','-DCMAKE_INSTALL_RPATH=@loader_path',
        '-DCMAKE_C_FLAGS=-mcpu=apple-m1 -fstack-protector-strong','-DCMAKE_CXX_FLAGS=-mcpu=apple-m1 -fstack-protector-strong',
        '-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTING=OFF','-DCMAKE_POLICY_VERSION_MINIMUM=3.5']

def run(name,extra):
    build=root/'build'/name
    with (root/'logs'/(name+'.log')).open('w') as log:
        subprocess.check_call([str(cmake),'-S',str(root/'sources'/name),'-B',str(build)]+common+extra,env=env,stdout=log,stderr=subprocess.STDOUT)
        subprocess.check_call([str(cmake),'--build',str(build),'-j','6'],env=env,stdout=log,stderr=subprocess.STDOUT)
        subprocess.check_call([str(cmake),'--install',str(build)],env=env,stdout=log,stderr=subprocess.STDOUT)
    print('Built',name,flush=True)

# Stable root-owned OpenSSL defaults; the bridge explicitly loads its own bundled providers.
# An installation/build path must never become a writable runtime configuration search path.
with (root/'logs/openssl.log').open('w') as log:
    directory=root/'sources/openssl-4.1.0'
    openssl_env=env.copy();openssl_env['CC']=clang
    subprocess.check_call(['./Configure','darwin64-arm64-cc','shared','no-tests','no-apps','no-docs','--prefix='+str(prefix),'--openssldir=/etc/ssl','-mmacosx-version-min=14.0','-mcpu=apple-m1','-isysroot',sdk],cwd=directory,env=openssl_env,stdout=log,stderr=subprocess.STDOUT)
    subprocess.check_call(['make','-j8','MODULESDIR=/usr/lib/ossl-modules','ENGINESDIR=/usr/lib/engines-4'],cwd=directory,env=openssl_env,stdout=log,stderr=subprocess.STDOUT)
    subprocess.check_call(['make','install_sw'],cwd=directory,env=openssl_env,stdout=log,stderr=subprocess.STDOUT)

stage1=[('SDL3-3.4.20',['-DSDL_SHARED=ON','-DSDL_STATIC=OFF','-DSDL_TESTS=OFF','-DSDL_TEST_LIBRARY=OFF','-DSDL_FRAMEWORK=OFF']),
        ('zlib-1.4',['-DZLIB_BUILD_TESTING=OFF','-DZLIB_BUILD_STATIC=OFF']),('json-c-0.19',['-DENABLE_WERROR=OFF','-DBUILD_TESTING=OFF']),
        ('uriparser-1.0.3',['-DURIPARSER_BUILD_TESTS=OFF','-DURIPARSER_BUILD_DOCS=OFF','-DURIPARSER_BUILD_TOOLS=OFF'])]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for result in pool.map(lambda pair:run(*pair),stage1):pass
stage2=[('opus-1.6.1',['-DOPUS_BUILD_TESTING=OFF','-DOPUS_BUILD_PROGRAMS=OFF','-DOPUS_INSTALL_PKG_CONFIG_MODULE=ON']),('fdk-aac-3.0.0',[]),
        ('freetype-2.15.0',['-DFT_DISABLE_HARFBUZZ=ON','-DFT_DISABLE_HVF=ON','-DFT_DISABLE_PNG=ON','-DFT_DISABLE_BZIP2=ON','-DFT_DISABLE_BROTLI=ON'])]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for result in pool.map(lambda pair:run(*pair),stage2):pass
run('SDL3_ttf-3.2.2',['-DCMAKE_PREFIX_PATH='+str(prefix),'-DSDLTTF_VENDORED=OFF','-DSDLTTF_HARFBUZZ=OFF','-DSDLTTF_PLUTOSVG=OFF','-DSDLTTF_SAMPLES=OFF'])

def autotools(name):
    directory=root/'sources'/name
    with (root/'logs'/(name+'.log')).open('w') as log:
        subprocess.check_call(['./configure','--prefix='+str(prefix),'--disable-static'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT)
        subprocess.check_call(['make','-j6'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT)
        subprocess.check_call(['make','install'],cwd=directory,env=env,stdout=log,stderr=subprocess.STDOUT)
    print('Built',name,flush=True)
for name in ['pkgconf-3.0.10','libusb-1.0.30']:autotools(name)
with (root/'logs/openh264.log').open('w') as log:
    command=['make','ARCH=arm64','OS=darwin','PREFIX='+str(prefix),'CFLAGS_OPT='+flags]
    subprocess.check_call(command+['-j6','libraries'],cwd=root/'sources/openh264-2.7.0',env=env,stdout=log,stderr=subprocess.STDOUT)
    subprocess.check_call(command+['install-shared'],cwd=root/'sources/openh264-2.7.0',env=env,stdout=log,stderr=subprocess.STDOUT)

for name in lock['patches']:
    if Path(name).name != name: raise ValueError('Unsafe native patch name')
    subprocess.check_call(['/usr/bin/patch','-p1','--batch','--forward','-i',str(repo/'scripts/native-patches'/name)],cwd=root/'sources/freerdp-3.33.1')
options=['-DCMAKE_PREFIX_PATH='+str(prefix),'-DPKG_CONFIG_EXECUTABLE='+str(prefix/'bin/pkgconf'),
         '-DOPENSSL_ROOT_DIR='+str(prefix),'-DOPENSSL_INCLUDE_DIR='+str(prefix/'include'),'-DOPENSSL_SSL_LIBRARY='+str(prefix/'lib/libssl.4.dylib'),'-DOPENSSL_CRYPTO_LIBRARY='+str(prefix/'lib/libcrypto.4.dylib'),
         '-DWITH_CLIENT_SDL=ON','-DWITH_CLIENT_SDL3=ON','-DWITH_CLIENT_MAC=OFF','-DWITH_CLIENT_SDL2=OFF','-DWITH_SERVER=OFF','-DWITH_SAMPLE=OFF',
         '-DWITH_FREERDP_DEPRECATED=ON','-DWITH_FREERDP_DEPRECATED_COMMANDLINE=ON','-DWITH_CLIENT_CHANNELS=ON','-DWITH_SERVER_CHANNELS=OFF',
         '-DWITH_FFMPEG=OFF','-DWITH_DSP_FFMPEG=OFF','-DWITH_VIDEO_FFMPEG=OFF','-DWITH_SWSCALE=OFF','-DWITH_CAIRO=OFF',
         '-DWITH_OPENH264=ON','-DWITH_GFX_H264=ON','-DWITH_FDK_AAC=ON','-DWITH_OPUS=ON','-DWITH_GSM=OFF','-DWITH_JPEG=OFF',
         '-DWITH_CUPS=ON','-DWITH_PCSC=ON','-DWITH_PKCS11=OFF','-DWITH_KRB5=OFF','-DWITH_FUSE=OFF','-DWITH_AAD=ON',
         '-DWITH_MANPAGES=OFF','-DWITH_DEBUG_ALL=OFF','-DWITH_VERBOSE_WINPR_ASSERT=OFF','-DWITH_CCACHE=OFF','-DWITH_CLANG_FORMAT=OFF','-DWITH_PROXY=OFF',
         '-DWITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF','-DWITH_ADD_PLUGIN_TO_RPATH=ON', '-DWITH_PLATFORM_SERVER=OFF','-DWITH_SHADOW=OFF']
run('freerdp-3.33.1',options)
with (root/'logs/bridge.log').open('w') as log:
    command=[clang,'-dynamiclib','-O2','-arch','arm64','-mcpu=apple-m1','-mmacosx-version-min=14.0','-isysroot',sdk,'-fno-objc-arc','-fobjc-exceptions','-fstack-protector-strong',
        '-I',str(prefix/'include/freerdp3'),'-I',str(prefix/'include/winpr3'),'-I',str(prefix/'include'),'-L',str(prefix/'lib')]
    command += [str(path) for path in sorted((repo/'Vendor/NethrivaRDPBridge').glob('*.m'))]
    command += ['-lfreerdp-client3','-lfreerdp3','-lwinpr3','-lssl','-lcrypto']
    for framework in ['Cocoa','Carbon','IOKit','Security','CoreVideo','CoreGraphics','CoreFoundation','ApplicationServices']:command += ['-framework',framework]
    command += ['-Wl,-install_name,@rpath/libNethrivaRDP.dylib','-Wl,-rpath,@loader_path','-o',str(prefix/'lib/libNethrivaRDP.dylib')]
    subprocess.check_call(command,env=env,stdout=log,stderr=subprocess.STDOUT)

out=root/'CandidateRuntime'
frameworks=out/'Frameworks'
if out.exists():raise SystemExit('Candidate already exists; choose an empty output to preserve evidence')
(out/'Frameworks/ossl-modules').mkdir(parents=True);(out/'MacOS').mkdir();(out/'ThirdPartyLicenses').mkdir()
frameworks=out/'Frameworks';mapping={};aliases={};queue=[prefix/'lib/libNethrivaRDP.dylib',prefix/'bin/sdl-freerdp',prefix/'lib/ossl-modules/legacy.dylib']
system=lambda p:p.startswith('/usr/lib/') or p.startswith('/System/Library/')
def dependencies(path):
    return [line.strip().split(' (compatibility',1)[0] for line in subprocess.check_output(['/usr/bin/otool','-L',str(path)],text=True).splitlines()[1:]]
def locate(dep,path):
    if dep.startswith('@rpath/'):
        options=[prefix/'lib'/dep[len('@rpath/'):],path.parent/dep[len('@rpath/'):]]
    elif dep.startswith('@loader_path/'):options=[path.parent/dep[len('@loader_path/'):]]
    elif dep.startswith('@executable_path/'):options=[prefix/'bin'/dep[len('@executable_path/'):]]
    else:options=[Path(dep)]
    for value in options:
        if value.is_file() and value.resolve().is_relative_to(prefix):return value
    raise ValueError('Unresolved non-system native dependency: '+dep)
while queue:
    requested=queue.pop(0);source=requested.resolve()
    if source not in mapping:
        if source==prefix/'bin/sdl-freerdp':target=out/'MacOS/sdl-freerdp'
        elif source.parent.name=='ossl-modules':target=frameworks/'ossl-modules'/source.name
        else:target=frameworks/source.name
        shutil.copy2(source,target);target.chmod(0o755);mapping[source]=target
        for dep in dependencies(source):
            if system(dep):continue
            value=locate(dep,source)
            if value.resolve()!=source:queue.append(value)
    if requested.name!=source.name:aliases[requested.name]=mapping[source]
for source,target in mapping.items():
    for dep in dependencies(source):
        if system(dep):continue
        resolved=locate(dep,source).resolve();dest=mapping[resolved]
        new='@rpath/'+str(dest.relative_to(frameworks)) if dest.is_relative_to(frameworks) else '@executable_path/'+dest.name
        # The first dylib dependency is its own install name; set it separately.
        if resolved==source:continue
        if dep!=new:subprocess.check_call(['/usr/bin/install_name_tool','-change',dep,new,str(target)])
    if target.suffix=='.dylib':subprocess.check_call(['/usr/bin/install_name_tool','-id','@rpath/'+str(target.relative_to(frameworks)),str(target)])
    load=subprocess.check_output(['/usr/bin/otool','-l',str(target)],text=True)
    old=re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',load)
    for path in dict.fromkeys(old):subprocess.check_call(['/usr/bin/install_name_tool','-delete_rpath',path,str(target)])
    desired='@executable_path/../Frameworks' if target.parent==out/'MacOS' else '@loader_path/..' if target.parent.name=='ossl-modules' else '@loader_path'
    subprocess.check_call(['/usr/bin/install_name_tool','-add_rpath',desired,str(target)])
for name,dest in aliases.items():
    alias=frameworks/name
    if not alias.exists():alias.symlink_to(dest.name)
for path in mapping.values():subprocess.check_call(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(path)])
licenses={'FreeRDP-LICENSE':'freerdp-3.33.1/LICENSE','OpenSSL-LICENSE.txt':'openssl-4.1.0/LICENSE.txt','SDL3-LICENSE.txt':'SDL3-3.4.20/LICENSE.txt','SDL3_ttf-LICENSE.txt':'SDL3_ttf-3.2.2/LICENSE.txt','FreeType-LICENSE.TXT':'freetype-2.15.0/docs/FTL.TXT','FreeType-GPLv2.TXT':'freetype-2.15.0/docs/GPLv2.TXT','FDK-AAC-NOTICE':'fdk-aac-3.0.0/NOTICE','Opus-COPYING':'opus-1.6.1/COPYING','OpenH264-LICENSE':'openh264-2.7.0/LICENSE','zlib-LICENSE':'zlib-1.4/LICENSE','libusb-COPYING':'libusb-1.0.30/COPYING','json-c-COPYING':'json-c-0.19/COPYING','uriparser-COPYING':'uriparser-1.0.3/COPYING'}
licenses['uriparser-COPYING']='uriparser-1.0.3/src/COPYING'
for name,relative in licenses.items():shutil.copy2(root/'sources'/relative,out/'ThirdPartyLicenses'/name)
lock=json.loads((root/'native-runtime.lock.json').read_text())
components=[]
for item in lock['components']:
    license={'id':item['license']} if item['license']!='FDK-AAC License' else {'name':item['license']}
    components.append({'type':'library','bom-ref':item['purl'],'name':item['name'],'version':item['version'],'purl':item['purl'],'licenses':[{'license':license}],
        'hashes':[{'alg':'SHA-256','content':item['sha256']}],'externalReferences':[{'type':'distribution','url':item['url']}]})
components.append({'type':'library','bom-ref':'urn:nethriva:native:WinPR:3.33.1','name':'WinPR','version':'3.33.1','purl':'pkg:github/FreeRDP/FreeRDP@3.33.1','licenses':[{'license':{'id':'Apache-2.0'}}]})
bom={'bomFormat':'CycloneDX','specVersion':'1.6','version':1,'serialNumber':'urn:uuid:'+str(uuid.uuid4()),'metadata':{'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'component':{'type':'application','name':'Nethriva native RDP runtime','version':'3.33.1'}},'components':components}
(out/'SBOM.cdx.json').write_text(json.dumps(bom,indent=2)+'\n')
provenance={'toolchain':{'xcode':subprocess.check_output(['/usr/bin/xcodebuild','-version'],env=env,text=True).strip(),'sdk':subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-version'],env=env,text=True).strip()},'schema':1,'architecture':'arm64','cpuBaseline':'apple-m1','minimumMacOS':'14.0','versions':{x['name']:x['version'] for x in lock['components']},'sourceLockSHA256':hashlib.sha256((root/'native-runtime.lock.json').read_bytes()).hexdigest(),'patches':lock['patches'],'patchHashes':{name:hashlib.sha256((repo/'scripts/native-patches'/name).read_bytes()).hexdigest() for name in lock['patches']},'bridgeSourcesSHA256':{str(x.relative_to(repo)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted((repo/'Vendor/NethrivaRDPBridge').glob('*')) if x.suffix in ['.m','.h']},'buildFlags':['-arch arm64','-mcpu=apple-m1','-mmacosx-version-min=14.0','-fstack-protector-strong'],'verification':'HTTPS official upstream release sources, pinned source SHA-256; detached PGP signatures not locally verified','nativeFiles':{str(x.relative_to(out)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(mapping.values())}}
provenance['versions']['WinPR']='3.33.1'
(out/'PROVENANCE.json').write_text(json.dumps(provenance,indent=2)+'\n')
(out/'README.txt').write_text('Nethriva bundled RDP runtime\n\nFreeRDP / WinPR version: 3.33.1\nOpenSSL version: 4.1.0\nArchitecture: Apple silicon arm64; M1 CPU baseline\nMinimum macOS version: 14.0\nClients: embedded Cocoa NSView bridge and SDL3 diagnostic fallback\n\nSources and exact hashes: scripts/native-runtime.lock.json in the source repository.\nNative component versions and source hashes: SBOM.cdx.json.\nBuild settings, bridge-source hashes and binary hashes: PROVENANCE.json.\nRecorded patches bound graphics allocations per surface/session and correct optional SDL event labels. See the source lock and patch hashes.\nAll runtime libraries are built from pinned sources, relocated to this bundle, and ad-hoc signed.\nThis does not provide Developer ID signing, notarization or live-server acceptance.\n')
print('Staged',len(mapping),'native binaries at',out)

subprocess.check_call(['/bin/zsh',str(repo/'scripts/validate-rdp-runtime.sh'),str(out),'arm64'])
print('Candidate ready; source resources and installed app were not modified:',out)
