#!/usr/bin/env python3
"""Fail-closed source-runtime integrity/version gate; no network or credentials."""
import argparse,ctypes,hashlib,json,platform,struct,subprocess,sys
from pathlib import Path

def require(value,message):
    if not value:raise ValueError(message)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime',type=Path)
    parser.add_argument('--lock',type=Path,default=Path(__file__).with_name('native-runtime.lock.json'))
    parser.add_argument('--skip-source-file-hashes',action='store_true',help='For a legitimately re-signed export; versions, pins, platform, signatures and provenance still checked.')
    args=parser.parse_args();runtime=args.runtime.resolve(strict=True);lock_raw=args.lock.read_bytes();lock=json.loads(lock_raw)
    provenance=json.loads((runtime/'PROVENANCE.json').read_bytes());bom=json.loads((runtime/'SBOM.cdx.json').read_bytes())
    require(lock.get('schema')==1 and provenance.get('schema')==1,'Unsupported native provenance schema')
    require(provenance.get('sourceLockSHA256')==hashlib.sha256(lock_raw).hexdigest(),'Native provenance does not match the checked-in source lock')
    require(provenance.get('patches')==lock.get('patches'),'Native hardening patches differ from the pinned build')
    patch_root=Path(__file__).parent/'native-patches'
    expected_patches={name:hashlib.sha256((patch_root/name).read_bytes()).hexdigest() for name in lock['patches'] if Path(name).name==name}
    require(len(expected_patches)==len(lock['patches']) and provenance.get('patchHashes')==expected_patches,'Native patch hash mismatch')
    require(provenance.get('architecture')==lock.get('architecture')=='arm64','Only the validated arm64 runtime is supported by this lock')
    require(provenance.get('cpuBaseline')=='apple-m1' and provenance.get('minimumMacOS')=='14.0','Native compatibility baseline changed')
    expected={x['name']:x['version'] for x in lock['components']};expected['WinPR']=expected['FreeRDP']
    require(provenance.get('versions')==expected,'Native versions differ from pinned components')
    actual_bom={x['name']:x['version'] for x in bom.get('components',[])}
    require(actual_bom==expected,'Native SBOM missing a component or has an unexpected version')
    require(bom.get('bomFormat')=='CycloneDX' and bom.get('specVersion')=='1.6','Invalid native SBOM format')
    declared=provenance.get('nativeFiles',{});require(len(declared)>=4,'Native file manifest is incomplete')
    listed={(runtime/name).resolve(strict=True) for name in declared}
    found_code=set()
    for candidate in runtime.rglob('*'):
        if candidate.is_symlink():require(candidate.resolve(strict=True).is_relative_to(runtime),'Runtime symlink escaped its root')
        if candidate.is_file():
            with candidate.open('rb') as stream:magic=stream.read(4)
            if magic in [b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']:found_code.add(candidate.resolve(strict=True))
    require(found_code==listed,'Runtime native file set differs from provenance (missing or extra code)')
    for relative,digest in declared.items():
        path=runtime/relative
        require(path.resolve(strict=True).is_relative_to(runtime),'Native path escaped runtime')
        if not args.skip_source_file_hashes:require(hashlib.sha256(path.read_bytes()).hexdigest()==digest,'Native file hash mismatch: '+relative)
        # Parse thin Mach-O ourselves: generic arm64, macOS platform, minimum <=14.
        data=path.read_bytes();header=struct.unpack_from('<8I',data)
        require(header[0]==0xfeedfacf and header[1]==0x0100000c and header[2]==0,'Native binary is not generic arm64: '+relative)
        offset=32;found=False
        for _ in range(header[4]):
            command,length=struct.unpack_from('<II',data,offset);require(length>=8 and offset+length<=len(data),'Invalid Mach-O load command')
            if command==0x32:
                platform_id,minimum=struct.unpack_from('<II',data,offset+8)
                require(platform_id==1 and minimum<=0x000e0000,'Native binary requires a different platform or macOS newer than14: '+relative);found=True
            offset+=length
        require(found,'Native binary has no macOS build-version command: '+relative)
        subprocess.check_call(['/usr/bin/codesign','--verify','--strict',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if platform.machine()=='arm64':
        lib=ctypes.CDLL(str(runtime/'Frameworks/libfreerdp3.3.dylib'));lib.freerdp_get_version_string.restype=ctypes.c_char_p
        crypto=ctypes.CDLL(str(runtime/('Frameworks/libcrypto.'+expected['OpenSSL'].split('.')[0]+'.dylib')));crypto.OpenSSL_version.restype=ctypes.c_char_p;crypto.OpenSSL_version.argtypes=[ctypes.c_int]
        require(lib.freerdp_get_version_string().decode()==expected['FreeRDP'],'Actual FreeRDP binary version mismatch')
        require(crypto.OpenSSL_version(0).decode().startswith('OpenSSL '+expected['OpenSSL']+' '),'Actual OpenSSL binary version mismatch')
        bridge=ctypes.CDLL(str(runtime/'Frameworks/libNethrivaRDP.dylib'))
        bridge.NethrivaRDPConfigureOpenSSL.argtypes=[ctypes.c_char_p];bridge.NethrivaRDPConfigureOpenSSL.restype=ctypes.c_int
        require(bridge.NethrivaRDPConfigureOpenSSL(str(runtime/'Frameworks/ossl-modules').encode())==1,'Bundled provider initialization failed')
        for symbol in ['NethrivaRDPSetConfigPath','NethrivaRDPVerifySystemCertificate']:require(getattr(bridge,symbol,None) is not None,'Missing required native security export')
    else:raise ValueError('Actual binary/provider validation requires an Apple-silicon Mac')
    print('PASS: pinned native versions, source-lock/SBOM/provenance, signed generic arm64/macOS14 binaries and provider initialization ('+str(len(declared))+' binaries).')

if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError,struct.error,subprocess.CalledProcessError) as error:
        print('FAIL: '+str(error),file=sys.stderr);sys.exit(1)
