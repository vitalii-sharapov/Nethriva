import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]
def module(name,file):
    spec=importlib.util.spec_from_file_location(name,SCRIPT/file);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
check=module('preflight_check','check-dependency-updates.py')
receipt=module('preflight_receipt','verify-dependency-preflight.py')

class DependencyPreflightTests(unittest.TestCase):
    def test_local_run_and_production_archive_keep_separate_signing_rules(self):
        import xml.etree.ElementTree as ET
        root = SCRIPT.parent
        project = plistlib.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'xml1', '-o', '-',
            str(root/'Nethriva.xcodeproj/project.pbxproj')]))
        objects = project['objects']
        app = next(value for value in objects.values()
                   if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'Nethriva')
        configurations = {objects[key]['name']: objects[key]['buildSettings']
                          for key in objects[app['buildConfigurationList']]['buildConfigurations']}
        for name in ['Development', 'Release']:
            self.assertEqual(configurations[name]['ENABLE_HARDENED_RUNTIME'], 'YES')
        local = plistlib.loads((root/configurations['Development']['CODE_SIGN_ENTITLEMENTS']).read_bytes())
        production = plistlib.loads((root/configurations['Release']['CODE_SIGN_ENTITLEMENTS']).read_bytes())
        self.assertIs(local['com.apple.security.cs.disable-library-validation'], True)
        self.assertNotIn('com.apple.security.cs.disable-library-validation', production)
        scheme = ET.parse(root/'Nethriva.xcodeproj/xcshareddata/xcschemes/Nethriva.xcscheme').getroot()
        self.assertEqual(scheme.find('LaunchAction').get('buildConfiguration'), 'Development')
        self.assertEqual(scheme.find('ArchiveAction').get('buildConfiguration'), 'Release')

    def test_build_receipt_write_matches_declared_sandbox_output(self):
        import shlex
        project = plistlib.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'xml1', '-o', '-',
            str(SCRIPT.parent/'Nethriva.xcodeproj/project.pbxproj')]))
        phase = next(value for value in project['objects'].values()
                     if value.get('name') == 'Verify Component Currency')
        invocation = next(line for line in phase['shellScript'].splitlines()
                          if 'verify-dependency-preflight.py' in line)
        output = shlex.split(invocation)[-1].replace('$DERIVED_FILE_DIR', '$(DERIVED_FILE_DIR)')
        self.assertIn(output, phase['outputPaths'])
        self.assertIn('!= Debug', phase['shellScript'])

    def test_rate_limit_uses_live_official_feed_and_immutable_public_ref(self):
        self.addCleanup(check.API_LIMITED.clear)
        check.API_LIMITED.clear()
        atom=b'<feed xmlns="http://www.w3.org/2005/Atom"><entry><link href="https://github.com/example/project/releases/tag/1.0.0"/></entry></feed>'
        pin=dict(name='Synthetic',version='1.0.0',revision='a'*40,repo='example/project',kind='tags',pattern=check.SEMVER)
        error=urllib.error.HTTPError('https://api.github.com',403,'rate limit',{},None)
        with patch.object(check,'get_json',side_effect=error),patch.object(check,'fetch',return_value=atom),patch.object(check,'public_git_tag',return_value='a'*40) as refs:
            result=check.check_item(pin)
            self.assertEqual(result['status'],'current');self.assertEqual(result['lookupTransport'],'fresh-official-atom');refs.assert_called_once()

    def test_rate_limit_and_unavailable_feed_still_fail_closed(self):
        self.addCleanup(check.API_LIMITED.clear)
        check.API_LIMITED.set()
        pin=dict(name='Synthetic',version='1.0.0',repo='example/project',kind='tags',pattern=check.SEMVER)
        with patch.object(check,'fetch',side_effect=OSError('unavailable')):
            self.assertEqual(check.check_item(pin)['status'],'unverified')

    def test_annotated_public_refs_peel_and_reject_unexpected_data(self):
        ref='refs/tags/v1.0.0'
        raw=(('b'*40)+'\t'+ref+'\n'+('a'*40)+'\t'+ref+'^{}\n').encode()
        self.assertEqual(check.parse_public_refs(raw,ref),'a'*40)
        with self.assertRaises(ValueError):check.parse_public_refs(b'not-a-digest refs/tags/v1.0.0',ref)

    def test_mixed_tag_names_compare_numerically_and_ignore_prereleases(self):
        tags=[{'name':'v4.0.2'},{'name':'4.5.2'},{'name':'4.6.0-alpha.1'}]
        version,tag,_=check.select_latest(tags,check.SEMVER,'tags')
        self.assertEqual(version,(4,5,2));self.assertEqual(tag,'4.5.2')

    def test_new_major_and_terminal_updates_fail_current_pin(self):
        for pinned,latest in [('3.5.9','4.1.0'),('1.20.0','1.99.3')]:
            pin=dict(name='Synthetic',version=pinned,repo='example/project',kind='releases',pattern=check.SEMVER)
            with patch.object(check,'github_versions',return_value=[{'tag_name':latest}]):
                self.assertEqual(check.check_item(pin)['status'],'outdated')

    def test_lookup_failure_is_unverified_not_success(self):
        pin=dict(name='Synthetic',version='1.0.0',repo='example/project',kind='tags',pattern=check.SEMVER)
        with patch.object(check,'github_versions',side_effect=OSError('unavailable')):
            self.assertEqual(check.check_item(pin)['status'],'unverified')

    def test_equal_version_with_changed_revision_is_refused(self):
        pin=dict(name='Synthetic',version='1.0.0',revision='a'*40,repo='example/project',kind='tags',pattern=check.SEMVER)
        with patch.object(check,'github_versions',return_value=[{'name':'1.0.0','commit':{'sha':'b'*40}}]):
            self.assertEqual(check.check_item(pin)['status'],'outdated')

    def test_action_bundle_is_not_mistaken_for_action_release(self):
        records=[{'tag_name':'codeql-bundle-v2.27.4'},{'tag_name':'v4.39.3'},{'tag_name':'v5.0.0','prerelease':True}]
        self.assertEqual(check.select_latest(records,check.SEMVER,'releases')[1],'v4.39.3')

    def test_current_receipt_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);path=root/'receipt.json'
            data=dict(schema=1,scope='all',managedCurrent=True,toolchainCurrent=True,checkedAt=time.time(),nonce='a'*32,inputHashes={'pins':'expected'},components=[{'name':'Synthetic','status':'current'}])
            path.write_text(json.dumps(data))
            with patch.object(receipt.check,'input_hashes',return_value={'pins':'expected'}),patch.object(receipt.check,'inventory',return_value=[{'name':'Synthetic'}]),patch.object(receipt.check,'verify_console_sources'):
                receipt.verify(path,root/'consumed')
                with self.assertRaises(ValueError):receipt.verify(path,root/'consumed')

    def test_stale_changed_failed_or_incomplete_receipt_blocks_build(self):
        cases=[{'checkedAt':time.time()-901},{'inputHashes':{'pins':'changed'}},{'managedCurrent':False},{'toolchainCurrent':False},{'components':[]}]
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);path=root/'receipt.json'
            for change in cases:
                data=dict(schema=1,scope='all',managedCurrent=True,toolchainCurrent=True,checkedAt=time.time(),nonce='a'*32,inputHashes={'pins':'expected'},components=[{'name':'Synthetic','status':'current'}]);data.update(change)
                path.write_text(json.dumps(data))
                with patch.object(receipt.check,'input_hashes',return_value={'pins':'expected'}),patch.object(receipt.check,'inventory',return_value=[{'name':'Synthetic'}]),patch.object(receipt.check,'verify_console_sources'):
                    with self.assertRaises(ValueError):receipt.verify(path,root/'consumed')

    def test_vendored_file_change_is_detected(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);base=root/'Nethriva/Resources/Consoles';(base/'noVNC').mkdir(parents=True);(base/'spice').mkdir()
            source=base/'noVNC/library.js';source.write_text('original')
            (base/'dependencies.lock.json').write_text(json.dumps({'components':[{'filesSHA256':{'noVNC/library.js':hashlib.sha256(b'original').hexdigest()}}]}))
            check.verify_console_sources(root)
            source.write_text('changed')
            with self.assertRaises(ValueError):check.verify_console_sources(root)

if __name__=='__main__':unittest.main()
