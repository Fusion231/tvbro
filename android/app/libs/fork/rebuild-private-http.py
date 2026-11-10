#!/usr/bin/env python3
"""Rebuild only JNI wrappers against an existing libdovi AAR; never build codecs."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, urllib.request
from pathlib import Path
from zipfile import ZipFile

FORK = '3c2f33cd7d09c75dbc340f86b2d34c55e94b7f99'
BASELINE = 'e8ad90ca2d23d68918b1062e0acd15182d16aaca7e63519526aa68bfee2ed99e'
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64')
SOURCES = {
    'main.cpp':'ff6050c751e4257bea1c2eddf78a68de8bb3987f',
    'render.cpp':'61d9cf9939d30995baf6951d0f72a4939443de13',
    'log.cpp':'7d3eb35d57facc0ea751d8770f1ac1a850cf685a',
    'jni_utils.cpp':'c91d4467cc1dff70a3738790cf609a59e3dc791d',
    'property.cpp':'39292233dc64d843b676d3f11b34adf108dd6383',
    'event.cpp':'b07d32196e91583d7e4272fb2c6975fe3660a932',
    'event.h':'ebb20d2de839b2d2890f9922dc1e87dca7e3e1f6',
    'globals.h':'8bf2c3b56ea82b0106c0bd536842adb4b85ba6c5',
    'jni_utils.h':'41afa2060f68f544942b0eb804712d6fcf01e845',
    'log.h':'26558335e21ad136a123d309f8f33cc0f54005ea',
}
HEADERS = {
    'mpv/client.h':('mpv-player/mpv','v0.41.0','include/mpv/client.h','85cff63bd5d20797ca622834fd904d506d0d4fd8'),
    'libavcodec/jni.h':('FFmpeg/FFmpeg','n8.1','libavcodec/jni.h','955cd28096b7eceafefce306681d9225673bb459'),
}
def sha(data): return hashlib.sha256(data).hexdigest()
def verified(data, blob):
    actual = hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if actual != blob: raise ValueError('Pinned upstream blob mismatch: '+blob)
    return data
def fetch(url, cached, blob):
    if cached and cached.exists(): return verified(cached.read_bytes(),blob)
    with urllib.request.urlopen(url,timeout=30) as response: return verified(response.read(256*1024),blob)
def apply_patch(root, text):
    lines=text.splitlines(); index=0
    while index<len(lines):
        if not lines[index].startswith('--- '): raise ValueError('Invalid patch header')
        index+=1; name=lines[index][6:]; index+=1
        if name not in {'libmpv/src/main/cpp/'+n for n in ('main.cpp','event.cpp','globals.h','property.cpp')}: raise ValueError('Unexpected patch target')
        target=root/name; original=target.read_text().splitlines(); result=[]; old=0
        while index<len(lines) and lines[index].startswith('@@ '):
            match=re.match(r'@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@',lines[index]); index+=1
            if not match: raise ValueError('Invalid patch hunk')
            start=int(match[1])-1; result.extend(original[old:start]); old=start
            while index<len(lines) and not lines[index].startswith(('@@ ','--- ')):
                line=lines[index];index+=1
                if line.startswith((' ','-')):
                    if old>=len(original) or original[old]!=line[1:]: raise ValueError('Patch context mismatch in '+name)
                    old+=1
                if line.startswith((' ','+')): result.append(line[1:])
                elif not line.startswith('-'): raise ValueError('Invalid patch line')
        result.extend(original[old:]);target.write_text('\n'.join(result)+'\n',encoding='utf-8')
def run(command, log):
    done=subprocess.run([str(x) for x in command],capture_output=True,text=True)
    with log.open('a',encoding='utf-8') as stream:stream.write(done.stdout+done.stderr)
    if done.returncode: raise RuntimeError('Command failed; inspect '+str(log))
    return done.stdout
def main():
    args=argparse.ArgumentParser(description=__doc__)
    args.add_argument('--input',type=Path,required=True);args.add_argument('--output',type=Path,required=True)
    args.add_argument('--work-dir',type=Path,required=True);args.add_argument('--ndk',type=Path,required=True)
    args.add_argument('--cmake',type=Path,required=True);args.add_argument('--ninja',type=Path,required=True)
    args.add_argument('--source-cache',type=Path,help='Optional verified source/include cache for offline builds')
    args=args.parse_args();here=Path(__file__).resolve().parent;work=args.work_dir.resolve()
    if args.input.resolve()==args.output.resolve():raise ValueError('Input and output must differ; preserve the baseline AAR')
    if work.exists() and any(work.iterdir()):raise ValueError('Use a new empty work directory; this script never deletes directories')
    work.mkdir(parents=True,exist_ok=True)
    original=args.input.read_bytes()
    if sha(original)!=BASELINE:raise ValueError('Input must be the exact documented baseline AAR; use its saved baseline for another rebuild')
    source=work/'source'/'libmpv'/'src'/'main'/'cpp';source.mkdir(parents=True)
    provenance={}
    for name,blob in SOURCES.items():
        url=f'https://raw.githubusercontent.com/GCHOfficial/libmpv-android/{FORK}/libmpv/src/main/cpp/{name}'
        cached=args.source_cache/'source'/name if args.source_cache else None
        data=fetch(url,cached,blob);(source/name).write_bytes(data);provenance[name]={'url':url,'gitBlob':blob,'sha256':sha(data)}
    for name,(repo,ref,path,blob) in HEADERS.items():
        url=f'https://raw.githubusercontent.com/{repo}/{ref}/{path}';cached=args.source_cache/'include'/name if args.source_cache else None
        data=fetch(url,cached,blob);target=work/'include'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        provenance[name]={'url':url,'gitBlob':blob,'sha256':sha(data)}
    patch=(here/'private-http-response.patch').read_bytes();apply_patch(work/'source',patch.decode())
    shutil.copyfile(here/'private_http_response.h',source/'private_http_response.h')
    shutil.copyfile(here/'private_http_headers.h',source/'private_http_headers.h')
    cmake=work/'CMakeLists.txt'
    cmake.write_text('''cmake_minimum_required(VERSION 3.22.1)
project(tvbro_private_http LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SRC "${CMAKE_CURRENT_LIST_DIR}/source/libmpv/src/main/cpp")
add_library(player SHARED "${SRC}/main.cpp" "${SRC}/render.cpp" "${SRC}/log.cpp" "${SRC}/jni_utils.cpp" "${SRC}/property.cpp" "${SRC}/event.cpp")
add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/prebuilt/${ANDROID_ABI}/libmpv.so")
add_library(avcodec SHARED IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/prebuilt/${ANDROID_ABI}/libavcodec.so")
target_include_directories(player PRIVATE "${CMAKE_CURRENT_LIST_DIR}/include")
target_link_libraries(player mpv avcodec log)
target_link_options(player PRIVATE "-Wl,-z,max-page-size=16384")
''')
    host='windows-x86_64' if os.name=='nt' else 'linux-x86_64';suffix='.exe' if os.name=='nt' else ''
    tools=args.ndk/'toolchains'/'llvm'/'prebuilt'/host/'bin';readelf=tools/('llvm-readelf'+suffix)
    replacements={};built=[];log=work/'build.log'
    with ZipFile(args.input) as archive:
        before={name:sha(archive.read(name)) for name in archive.namelist()}
        for abi in ABIS:
            prebuilt=work/'prebuilt'/abi;prebuilt.mkdir(parents=True)
            for name in ('libmpv.so','libavcodec.so','libplayer.so'):(prebuilt/name).write_bytes(archive.read(f'jni/{abi}/{name}'))
            build=work/'build'/abi
            run([args.cmake,'-S',work,'-B',build,'-G','Ninja','-DCMAKE_MAKE_PROGRAM='+args.ninja.as_posix(),
                '-DCMAKE_TOOLCHAIN_FILE='+(args.ndk/'build'/'cmake'/'android.toolchain.cmake').as_posix(),
                '-DANDROID_ABI='+abi,'-DANDROID_PLATFORM=android-26','-DANDROID_STL=c++_shared','-DCMAKE_BUILD_TYPE=Release'],log)
            run([args.cmake,'--build',build,'--parallel','4'],log)
            wrapper=build/'libplayer.so';run([tools/('llvm-strip'+suffix),'--strip-unneeded',wrapper],log)
            exports=lambda path:sorted(set(re.findall(r'Java_dev_jdtech_mpv_MPVLib_\w+',run([readelf,'--dyn-syms','--wide',path],log))))
            if exports(wrapper)!=exports(prebuilt/'libplayer.so'):raise ValueError('JNI exports changed')
            replacements[f'jni/{abi}/libplayer.so']=wrapper.read_bytes();built.append({'abi':abi,'bytes':wrapper.stat().st_size,'sha256':sha(wrapper.read_bytes()),'jniExports':16})
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with ZipFile(args.output,'w') as result:
            for info in archive.infolist():result.writestr(info,replacements.get(info.filename,archive.read(info.filename)))
    with ZipFile(args.output) as result:after={name:sha(result.read(name)) for name in result.namelist()}
    if before.keys()!=after.keys() or {name for name in before if before[name]!=after[name]}!=set(replacements):raise ValueError('Unexpected AAR entry change')
    manifest={'status':'passed','baselineAarSha256':sha(original),'outputAarSha256':sha(args.output.read_bytes()),'forkCommit':FORK,
        'patchSha256':sha(patch),'parserSha256':sha((here/'private_http_response.h').read_bytes()),'headersParserSha256':sha((here/'private_http_headers.h').read_bytes()),'ndk':str(args.ndk),'cmake':str(args.cmake),
        'sources':provenance,'wrappers':built,'changedEntries':list(replacements),'classesJarUnchanged':before['classes.jar']==after['classes.jar'],
        'beforeEntries':before,'afterEntries':after,'note':'Compiler/toolchain version and build paths can change wrapper build IDs; all non-wrapper entry bytes remain identical.'}
    Path(str(args.output)+'.provenance.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps({key:manifest[key] for key in ('status','outputAarSha256','changedEntries','classesJarUnchanged')}))
if __name__=='__main__':main()
