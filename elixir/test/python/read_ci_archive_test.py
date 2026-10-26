import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import tempfile
import time
import unittest
import warnings

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('reader',HERE.parent.parent/'priv'/'read_ci_archive_v2.py')
reader=importlib.util.module_from_spec(spec); spec.loader.exec_module(reader)

class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='fixture-',dir=HERE)
        self.root=Path(self.temp.name); self.path=self.root/'artifact.zip'
    def tearDown(self): self.temp.cleanup()
    def zip(self,items):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            with zipfile.ZipFile(self.path,'w',compression=zipfile.ZIP_DEFLATED) as out:
                for name,data in items: out.writestr(name,data)
        self.path.chmod(0o600)
    def request(self,names):
        raw=self.path.read_bytes()
        return {'version':1,'archive_path':str(self.path),'expected_sha256':hashlib.sha256(raw).hexdigest(),'expected_size':len(raw),'source_root':'/nonexistent-source-boundary','download_root':str(self.root),'selected_members':names}
    def codes(self,result): return [gap['code'] for gap in result['gaps']]
    def test_text_and_gzip_complete(self):
        self.zip([('tests/a/test.log',b'passed\n'),('tests/b/test.xml.gz',gzip.compress(b'<testsuite/>'))])
        result=reader.decode(self.request(['tests/a/test.log','tests/b/test.xml.gz']))
        self.assertEqual(result['gaps'],[]); self.assertEqual([m['text'] for m in result['members']],['passed\n','<testsuite/>'])
        self.assertTrue(all(m['complete'] for m in result['members']))
    def test_gzip_bomb_is_gap_never_partial(self):
        self.zip([('test.log.gz',gzip.compress(b'x'*(reader.MAX_MEMBER+1)))])
        result=reader.decode(self.request(['test.log.gz']))
        self.assertEqual(result['members'],[]); self.assertIn('member_size',self.codes(result))
    def test_zip_bomb_ratio_preflight(self):
        self.zip([('test.log',b'x'*(2*1024*1024))])
        result=reader.decode(self.request(['test.log']))
        self.assertIn('zip_ratio',self.codes(result)); self.assertEqual(result['members'],[])
    def test_archive_count_before_zipfile_allocation(self):
        self.zip([('test.log',b'ok')]); raw=bytearray(self.path.read_bytes()); pos=raw.rfind(b'PK\x05\x06')
        struct.pack_into('<H',raw,pos+8,257); struct.pack_into('<H',raw,pos+10,257); self.path.write_bytes(raw)
        with unittest.mock.patch.object(reader.zipfile,'ZipFile',side_effect=AssertionError('must not allocate')):
            self.assertIn('zip_directory_limit',self.codes(reader.decode(self.request(['test.log']))))
    def test_central_bytes_before_zipfile_allocation(self):
        self.zip([('test.log',b'ok')]); raw=bytearray(self.path.read_bytes()); pos=raw.rfind(b'PK\x05\x06')
        struct.pack_into('<L',raw,pos+12,reader.MAX_CENTRAL+1); self.path.write_bytes(raw)
        with unittest.mock.patch.object(reader.zipfile,'ZipFile',side_effect=AssertionError('must not allocate')):
            self.assertIn('zip_directory_limit',self.codes(reader.decode(self.request(['test.log']))))
    def test_crc_corruption(self):
        self.zip([('test.log.gz',gzip.compress(b'valid log text'))]); raw=bytearray(self.path.read_bytes())
        offset=30+struct.unpack_from('<H',raw,26)[0]+struct.unpack_from('<H',raw,28)[0]; raw[offset]^=0x10; self.path.write_bytes(raw)
        result=reader.decode(self.request(['test.log.gz'])); self.assertEqual(result['members'],[]); self.assertIn('member_corrupt',self.codes(result))
    def test_gzip_crc_and_truncation(self):
        for data in [gzip.compress(b'ok')[:-3],gzip.compress(b'ok')[:-8]+b'\x00'*8]:
            self.zip([('test.log.gz',data)]); result=reader.decode(self.request(['test.log.gz']))
            self.assertEqual(result['members'],[]); self.assertIn('member_corrupt',self.codes(result))
    def test_traversal_duplicate_case_and_parent_collisions(self):
        for names in [['../test.log'],['test.log','test.log'],['A/test.log','a/test.log'],['dir','dir/test.log']]:
            self.zip([(name,b'ok') for name in names]); result=reader.decode(self.request(['missing.log']))
            self.assertEqual(result['members'],[]); self.assertTrue(result['gaps'])
    def test_symlink_rejected(self):
        info=zipfile.ZipInfo('test.log'); info.create_system=3; info.external_attr=(stat.S_IFLNK|0o777)<<16
        self.zip([(info,b'/outside')]); self.assertIn('member_special',self.codes(reader.decode(self.request(['test.log']))))
    def test_encrypted_flag_rejected(self):
        self.zip([('test.log',b'ok')]); raw=bytearray(self.path.read_bytes()); central=raw.find(b'PK\x01\x02'); flags=struct.unpack_from('<H',raw,central+8)[0]; struct.pack_into('<H',raw,central+8,flags|1); self.path.write_bytes(raw)
        self.assertIn('zip_encryption_or_method',self.codes(reader.decode(self.request(['test.log']))))
    def test_invalid_utf8_and_replacement_character(self):
        for data in [b'\xff', '\ufffd'.encode()]:
            self.zip([('test.log',data)]); result=reader.decode(self.request(['test.log']))
            self.assertEqual(result['members'],[]); self.assertTrue(set(self.codes(result))&{'member_utf8','replacement_character'})
    def test_aggregate_limit(self):
        data=(b'abcdefghijklmnopqrstuvwxyz0123456789\n'*11000)
        self.zip([(str(n)+'.log',data) for n in range(3)])
        result=reader.decode(self.request([str(n)+'.log' for n in range(3)]))
        self.assertIn('aggregate_size',self.codes(result))
    def test_permission_hash_source_and_missing_gaps(self):
        self.zip([('test.log',b'ok')]); good=self.request(['test.log'])
        for key,value in [('expected_sha256','0'*64),('source_root',str(self.root))]:
            request={**good,key:value}; self.assertTrue(reader.decode(request)['gaps'])
        self.path.chmod(0o644); self.assertIn('archive_private_regular',self.codes(reader.decode(good)))
        self.path.unlink(); self.assertTrue(reader.decode(good)['gaps'])
    def test_symlink_hardlink_and_nonprivate_root_denied(self):
        self.zip([('test.log',b'ok')]); request=self.request(['test.log'])
        link=self.root/'linked.zip'; os.link(self.path,link)
        self.assertIn('archive_private_regular',self.codes(reader.decode(request))); link.unlink()
        link.symlink_to(self.path); request['archive_path']=str(link)
        self.assertIn('canonical_path',self.codes(reader.decode(request))); link.unlink()
        request=self.request(['test.log']); self.root.chmod(0o755)
        self.assertIn('download_root_private',self.codes(reader.decode(request))); self.root.chmod(0o700)
    def test_final_identity_change_discards_all_content(self):
        self.zip([('test.log',b'ok')]); request=self.request(['test.log'])
        original=reader.archive_bytes; count=[0]
        def changed(*args):
            raw,identity=original(*args); count[0]+=1
            return raw,(identity if count[0]==1 else ('changed',))
        with unittest.mock.patch.object(reader,'archive_bytes',side_effect=changed): result=reader.decode(request)
        self.assertEqual(result['members'],[]); self.assertIn('archive_changed',self.codes(result))
    def test_selection_missing_and_suffix_denied(self):
        self.zip([('test.log',b'ok')])
        self.assertIn('selected_missing',self.codes(reader.decode(self.request(['missing.log']))))
        self.assertIn('selected_suffix',self.codes(reader.decode(self.request(['file.sh']))))
    def test_deadline_and_archive_bound(self):
        self.zip([('test.log',b'ok')])
        with self.assertRaises(reader.Gap): reader.decode(self.request(['test.log']),time.monotonic()-1)
        request=self.request(['test.log']); request['expected_size']=reader.MAX_ARCHIVE+1
        self.assertIn('archive_size',self.codes(reader.decode(request)))
    def test_open_stdin_framed_native_child(self):
        self.zip([('test.log',b'ok')]); request=self.request(['test.log'])
        process=subprocess.Popen(['/usr/bin/python3','-I','-S','-B',str(HERE.parent.parent/'priv'/'read_ci_archive_v2.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            process.stdin.write(json.dumps(request).encode()+b'\n'); process.stdin.flush()
            self.assertTrue(select.select([process.stdout],[],[],7)[0],'child did not answer with open stdin')
            result=json.loads(process.stdout.readline(reader.MAX_OUTPUT+2))
            self.assertEqual(result['gaps'],[]); self.assertEqual(result['members'][0]['text'],'ok')
            self.assertEqual(process.wait(timeout=2),0); self.assertEqual(process.stderr.read(),b'')
        finally:
            if process.poll() is None: process.kill(); process.wait()
            process.stdin.close(); process.stdout.close(); process.stderr.close()

import zipfile
from unittest import mock
if __name__=='__main__': unittest.main()
