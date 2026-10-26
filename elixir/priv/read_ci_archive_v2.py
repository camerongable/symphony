"""Bounded read-only CI artifact decoder. Caller redacts text before persistence/model use."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import sys
import time
import unicodedata
import zipfile
import zlib

MAX_INPUT=16*1024
MAX_ARCHIVE=64*1024*1024
MAX_MEMBERS=256
MAX_CENTRAL=256*1024
MAX_MEMBER=512*1024
MAX_TOTAL=1024*1024
MAX_OUTPUT=8*1024*1024
MAX_RATIO=1000
SECONDS=5

class Gap(Exception):
    def __init__(self,code): self.code=code

def require(value,code):
    if not value: raise Gap(code)

def check_time(deadline): require(time.monotonic()<=deadline,'deadline')
def digest(raw): return hashlib.sha256(raw).hexdigest()
def strict_object(pairs):
    out={}
    for key,value in pairs:
        require(key not in out,'duplicate_request_key'); out[key]=value
    return out
def member_name(name):
    require(isinstance(name,str) and 0<len(name.encode('utf-8'))<=1024,'member_name')
    require(not any(ord(c)<32 or ord(c)==127 for c in name) and '\\' not in name and not name.startswith('/') and not re.match(r'^[A-Za-z]:',name),'member_path')
    require(unicodedata.normalize('NFC',name)==name,'member_normalization')
    trimmed=name[:-1] if name.endswith('/') else name
    require(trimmed and all(p not in ('','.','..') for p in trimmed.split('/')),'member_path')
    return trimmed.casefold()
def selected_name(name):
    member_name(name)
    require(not name.endswith('/') and re.search(r'\.(?:log|txt|xml|json)(?:\.gz)?$',name,re.IGNORECASE),'selected_suffix')
def central_directory(raw,deadline):
    check_time(deadline)
    eocd=raw.rfind(b'PK\x05\x06',max(0,len(raw)-65557))
    require(eocd>=0 and eocd+22<=len(raw),'zip_eocd')
    _,disk,central_disk,disk_count,count,size,offset,comment=struct.unpack_from('<4s4H2LH',raw,eocd)
    require(eocd+22+comment==len(raw),'zip_trailing_bytes')
    require(disk==central_disk==0 and disk_count==count,'zip_multidisk')
    require(count<=MAX_MEMBERS and count!=65535 and size<=MAX_CENTRAL and offset!=0xffffffff,'zip_directory_limit')
    require(offset+size==eocd and offset>=0,'zip_directory_bounds')
    cursor=offset; names={}; files=set(); entries=[]
    for _ in range(count):
        check_time(deadline)
        require(cursor+46<=eocd,'zip_directory_truncated')
        fields=struct.unpack_from('<4s6H3L5H2L',raw,cursor)
        require(fields[0]==b'PK\x01\x02','zip_directory_signature')
        flags,method=fields[3],fields[4]
        compressed,expanded=fields[8],fields[9]
        name_len,extra_len,comment_len=fields[10:13]
        external,local=fields[15],fields[16]
        end=cursor+46+name_len+extra_len+comment_len
        require(end<=eocd and name_len>0,'zip_directory_entry_bounds')
        require(not flags&1 and method in (0,8),'zip_encryption_or_method')
        require(compressed!=0xffffffff and expanded!=0xffffffff and local+30<=offset,'zip64_or_local_bounds')
        require(expanded<=MAX_ARCHIVE*MAX_RATIO and expanded<=max(1,compressed)*MAX_RATIO,'zip_ratio')
        name_raw=raw[cursor+46:cursor+46+name_len]
        require(bool(flags&0x800) or name_raw.isascii(),'member_encoding_flag')
        try: name=name_raw.decode('utf-8','strict')
        except UnicodeError: raise Gap('member_utf8')
        key=member_name(name); require(key not in names,'member_collision')
        mode=(external>>16)&0xffff; kind=stat.S_IFMT(mode)
        require(kind in (0,stat.S_IFREG,stat.S_IFDIR),'member_special')
        directory=name.endswith('/')
        require(kind!=stat.S_IFDIR or directory,'member_directory_mode')
        names[key]=name
        if not directory: files.add(key)
        entries.append((name,compressed,expanded,directory))
        cursor=end
    require(cursor==offset+size,'zip_directory_count')
    for key in names:
        require(not any('/'.join(key.split('/')[:i]) in files for i in range(1,len(key.split('/')))),'member_parent_collision')
    return entries
def bounded_read(stream,limit,deadline):
    chunks=[]; count=0
    while True:
        check_time(deadline)
        chunk=stream.read(min(32768,limit-count+1))
        if not chunk: break
        count+=len(chunk); require(count<=limit,'member_size')
        chunks.append(chunk)
    return b''.join(chunks)
def archive_bytes(request,deadline):
    require(set(request)=={'version','archive_path','expected_sha256','expected_size','source_root','download_root','selected_members'},'request_fields')
    require(type(request['version']) is int and request['version']==1,'request_version')
    require(isinstance(request['expected_sha256'],str) and re.fullmatch('[0-9a-f]{64}',request['expected_sha256']),'archive_digest')
    size=request['expected_size']; require(type(size) is int and 0<size<=MAX_ARCHIVE,'archive_size')
    require(isinstance(request['selected_members'],list) and 0<len(request['selected_members'])<=MAX_MEMBERS,'selected_members')
    for name in request['selected_members']: selected_name(name)
    require(len(set(request['selected_members']))==len(request['selected_members']),'selected_collision')
    root=Path(request['download_root']); source=Path(request['source_root']); path=Path(request['archive_path'])
    require(all(p.is_absolute() and p.resolve()==p for p in [root,source,path]),'canonical_path')
    require(path.parent==root and not path.is_relative_to(source) and not root.is_relative_to(source),'source_containment')
    root_before=root.stat(); require(stat.S_ISDIR(root_before.st_mode) and root_before.st_uid==os.getuid() and stat.S_IMODE(root_before.st_mode)==0o700,'download_root_private')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and stat.S_IMODE(before.st_mode)==0o600 and before.st_nlink==1,'archive_private_regular')
        require(before.st_size==size,'archive_size_changed')
        chunks=[]; read_size=0
        while True:
            check_time(deadline); chunk=os.read(fd,min(65536,MAX_ARCHIVE-read_size+1))
            if not chunk: break
            read_size+=len(chunk); require(read_size<=MAX_ARCHIVE,'archive_size'); chunks.append(chunk)
        raw=b''.join(chunks); after=os.fstat(fd)
        identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_mode,s.st_uid,s.st_nlink)
        require(identity(before)==identity(after)==identity(path.stat()),'archive_changed')
        require((root.stat().st_dev,root.stat().st_ino)==(root_before.st_dev,root_before.st_ino),'download_root_changed')
        require(len(raw)==size and digest(raw)==request['expected_sha256'],'archive_hash_changed')
        return raw,identity(before)
    finally: os.close(fd)
def decode(request,deadline=None):
    deadline=time.monotonic()+SECONDS if deadline is None else deadline
    result={'version':1,'archive_sha256':request.get('expected_sha256'),'members':[],'gaps':[]}
    try:
        raw,original_identity=archive_bytes(request,deadline); entries=central_directory(raw,deadline)
        by_name={name:(compressed,expanded,directory) for name,compressed,expanded,directory in entries}
        total=0
        with zipfile.ZipFile(io.BytesIO(raw),'r') as archive:
            require(len(archive.infolist())==len(entries),'zip_parser_count')
            for name in request['selected_members']:
                check_time(deadline)
                try:
                    require(name in by_name and not by_name[name][2],'selected_missing')
                    compressed,expanded,_=by_name[name]
                    layer_limit=MAX_ARCHIVE if name.lower().endswith('.gz') else MAX_MEMBER
                    require(expanded<=layer_limit,'member_size')
                    with archive.open(name,'r') as member: content=bounded_read(member,layer_limit,deadline)
                    require(len(content)==expanded,'member_incomplete')
                    if name.lower().endswith('.gz'):
                        encoded_size=len(content)
                        with gzip.GzipFile(fileobj=io.BytesIO(content),mode='rb') as inner: content=bounded_read(inner,MAX_MEMBER,deadline)
                        require(len(content)<=max(1,encoded_size)*MAX_RATIO,'gzip_ratio')
                    require(total+len(content)<=MAX_TOTAL,'aggregate_size')
                    text=content.decode('utf-8','strict'); require('\ufffd' not in text,'replacement_character')
                    candidate={'path':name,'sha256':digest(content),'text':text,'complete':True}
                    trial={**result,'members':result['members']+[candidate]}
                    require(len(json.dumps(trial,ensure_ascii=True).encode())<=MAX_OUTPUT-4096,'output_size')
                    total+=len(content); result['members'].append(candidate)
                except Gap as error: result['gaps'].append({'code':error.code,'path':name})
                except UnicodeError: result['gaps'].append({'code':'member_utf8','path':name})
                except (OSError,EOFError,ValueError,RuntimeError,KeyError,zipfile.BadZipFile,zlib.error): result['gaps'].append({'code':'member_corrupt','path':name})
        _,final_identity=archive_bytes(request,deadline)
        require(original_identity==final_identity,'archive_changed')
    except Gap as error:
        result['members']=[]; result['gaps'].append({'code':error.code})
    except (OSError,TypeError,ValueError,UnicodeError,zipfile.BadZipFile,struct.error):
        result['members']=[]; result['gaps'].append({'code':'archive_unavailable_or_corrupt'})
    check_time(deadline)
    return result
def main():
    result={'version':1,'archive_sha256':None,'members':[],'gaps':[]}
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE,(0,0)); resource.setrlimit(resource.RLIMIT_FSIZE,(0,0))
        resource.setrlimit(resource.RLIMIT_CPU,(4,4)); resource.setrlimit(resource.RLIMIT_NOFILE,(32,32))
        line=sys.stdin.buffer.readline(MAX_INPUT+1)
        require(len(line)<=MAX_INPUT and line.endswith(b'\n'),'request_frame')
        request=json.loads(line.decode('utf-8','strict'),object_pairs_hook=strict_object,parse_constant=lambda _: (_ for _ in ()).throw(Gap('request_number')))
        require(isinstance(request,dict),'request_object')
        result=decode(request)
    except Gap as error: result['gaps']=[{'code':error.code}]
    except (OSError,ValueError,TypeError,MemoryError,UnicodeError): result['gaps']=[{'code':'request_or_resource_unavailable'}]
    raw=json.dumps(result,ensure_ascii=True,separators=(',',':')).encode()
    if len(raw)>MAX_OUTPUT: raw=b'{"version":1,"archive_sha256":null,"members":[],"gaps":[{"code":"output_size"}]}'
    sys.stdout.buffer.write(raw+b'\n'); sys.stdout.buffer.flush()
if __name__=='__main__': main()
