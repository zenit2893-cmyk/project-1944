"""Read-only audit of the user-supplied Xenia reference package; never executes it."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import urllib.request

import pefile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--offline', action='store_true', help='Use the retained official release metadata')
args = parser.parse_args()
workspace = Path(__file__).resolve().parent.parent
reports = workspace / 'docs/reports'
reports.mkdir(parents=True, exist_ok=True)
exe = workspace / 'xenia_canary.exe'
archive = workspace / 'xenia_canary_windows.7z'
license_file = workspace / 'LICENSE'
reference = workspace / 'tools/xenia-reference-bin'
source = workspace / 'tools/Xenia-source'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

original_hashes = {p.name: sha(p) for p in (exe, archive, license_file)}
data = exe.read_bytes()
ascii_strings = [s.decode('ascii') for s in re.findall(rb'[\x20-\x7e]{5,}', data)]
wide_strings = [s.decode('utf-16-le') for s in re.findall(rb'(?:[\x20-\x7e]\x00){5,}', data)]
commit_matches = sorted(set(re.findall(
    rb'https://github\.com/xenia-canary/xenia-canary/commit/([0-9a-f]{40})', data)))
if len(commit_matches) != 1:
    raise RuntimeError('Expected exactly one embedded Xenia source commit')
commit = commit_matches[0].decode('ascii')
if commit != '0e1307bd2e6bfeeff29635a6b823e72e61c97ce9':
    raise RuntimeError('The Xenia artifact changed; refresh the pinned source-dependency audit before reusing it')
tag = commit[:7]
release_api = f'https://api.github.com/repos/xenia-canary/xenia-canary/releases/tags/{tag}'
release_path = reports / 'xenia-dependencies-release.json'
if args.offline:
    release = json.loads(release_path.read_text(encoding='utf-8-sig'))
else:
    request = urllib.request.Request(release_api, headers={'User-Agent': 'cod3-local-artifact-audit'})
    with urllib.request.urlopen(request, timeout=20) as response:
        release = json.load(response)
    release_path.write_text(json.dumps(release, indent=2), encoding='utf-8')
asset = next(a for a in release['assets'] if a['name'] == archive.name)
official_digest = asset['digest'].removeprefix('sha256:').lower()
archive_entries = subprocess.check_output(
    ['tar.exe', '-tf', str(archive)], text=True, encoding='utf-8').splitlines()
layout_expected = sorted(archive_entries) == ['LICENSE', 'xenia_canary.exe']
payloads_match = all((reference / p.name).is_file() and sha(reference / p.name) == sha(p)
                     for p in (exe, license_file))

with pefile.PE(str(exe), fast_load=True) as pe:
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY[name] for name in (
        'IMAGE_DIRECTORY_ENTRY_IMPORT', 'IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT', 'IMAGE_DIRECTORY_ENTRY_EXPORT')])
    imports = []
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        name = entry.dll.decode('ascii')
        is_api_set = name.lower().startswith(('api-ms-', 'ext-ms-'))
        imports.append({
            'dll': name, 'imported_symbol_count': len(entry.imports),
            'kind': 'windows_api_set_contract' if is_api_set else
                    'msvc_runtime' if name.lower().startswith(('msvcp', 'vcruntime')) else 'windows_system',
            'system32_file_present': None if is_api_set else (Path(os.environ['WINDIR']) / 'System32' / name).is_file()
        })
    exports = []
    for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols:
        section = pe.get_section_by_rva(symbol.address)
        exports.append({'name': symbol.name.decode('ascii'), 'rva': hex(symbol.address),
                        'in_executable_section': bool(section.Characteristics & 0x20000000)})
    pe_report = {'architecture': 'x86_64' if pe.FILE_HEADER.Machine == 0x8664 else hex(pe.FILE_HEADER.Machine),
                 'subsystem': 'Windows GUI' if pe.OPTIONAL_HEADER.Subsystem == 2 else pe.OPTIONAL_HEADER.Subsystem,
                 'timestamp_utc': datetime.datetime.fromtimestamp(pe.FILE_HEADER.TimeDateStamp, datetime.timezone.utc).isoformat(),
                 'imports': imports, 'delay_imports': [e.dll.decode('ascii') for e in getattr(pe, 'DIRECTORY_ENTRY_DELAY_IMPORT', [])],
                 'exports': exports}

source_refs = [
    ('third_party/CMakeLists.txt', 140, 'fmt compiled STATIC'),
    ('third_party/CMakeLists.txt', 166, 'ImGui compiled STATIC'),
    ('third_party/CMakeLists.txt', 242, 'zstd compiled STATIC'),
    ('third_party/CMakeLists.txt', 444, 'SDL2 compiled STATIC on Windows; native ReXGlue uses SDL3'),
    ('third_party/CMakeLists.txt', 571, 'libavutil compiled STATIC'),
    ('third_party/CMakeLists.txt', 688, 'libavcodec compiled STATIC'),
    ('third_party/CMakeLists.txt', 792, 'libavformat compiled STATIC'),
    ('src/xenia/ui/d3d12/d3d12_provider.cc', 170, 'Optional D3DCompiler_47, dxilconv and dxcompiler are used for debug disassembly'),
    ('src/xenia/hid/sdl/sdl_input_driver.cc', 26, 'Optional gamecontrollerdb.txt mapping file'),
    ('src/xenia/hid/sdl/sdl_input_driver.cc', 163, 'SDL2 mappings passed through SDL_GameControllerAddMapping'),
]
source_evidence = [{'file': str(source / name), 'line': line, 'finding': finding,
                    'url': f'https://github.com/xenia-canary/xenia-canary/blob/{commit}/{name}#L{line}'}
                   for name, line, finding in source_refs]
git = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/native/git/cmd/git.exe'
source_commit = subprocess.check_output([str(git), '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()

report = {
    'schema_version': 1, 'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'PASS' if original_hashes[archive.name] == official_digest and payloads_match and layout_expected and source_commit == commit else 'FAIL',
    'scope': 'Package identity, PE imports/exports, and pinned-source dependency audit; no emulator/game execution',
    'execution_performed': False, 'source_commit': commit, 'source_checkout_commit': source_commit,
    'embedded_build_strings': sorted(set(s for s in ascii_strings if s.startswith(('canary_experimental@', 'Build: canary_experimental@')))),
    'files': [{'path': str(p), 'bytes': p.stat().st_size, 'sha256': original_hashes[p.name]} for p in (exe, archive, license_file)],
    'official_release': {'api_url': release_api, 'url': release['html_url'], 'tag': release['tag_name'],
                         'target_commit': release['target_commitish'], 'published_at': release['published_at'],
                         'asset_url': asset['browser_download_url'], 'asset_bytes': asset['size'],
                         'asset_sha256': official_digest, 'archive_hash_matches': original_hashes[archive.name] == official_digest,
                         'metadata_mode': 'retained_official_response' if args.offline else 'refreshed_official_response'},
    'archive_entries': archive_entries, 'archive_layout_expected': layout_expected,
    'reference_directory': str(reference), 'reference_payloads_match_user_files': payloads_match,
    'authenticode': 'NotSigned (checked with PowerShell Get-AuthenticodeSignature); release archive digest is the provenance evidence',
    'pe': pe_report,
    'dll_name_string_candidates': sorted(set(s for s in ascii_strings + wide_strings if re.fullmatch(r'[A-Za-z0-9_.-]+\.dll', s, re.I))),
    'dll_strings_limitation': 'Strings may include optional paths or unused backends; they are not a required-dependency list',
    'source_evidence': source_evidence,
    'reuse': [
        {'component': 'Renderer, SDL2, FFmpeg, fmt, ImGui, zstd', 'archive_payload': 'compiled into EXE',
         'native_reuse': 'Adapt pinned source changes and rebuild native SDK/plugin; EXE exposes no graphics/plugin API'},
        {'component': 'DXC', 'archive_payload': 'absent',
         'native_reuse': 'Existing x64 DXC at tools/XenosRecomp/thirdparty/dxc-bin/bin/x64 can be used as a separate shader tool; preserve its own license'},
        {'component': 'gamecontrollerdb.txt', 'archive_payload': 'absent',
         'native_reuse': 'Optional data can be supplied separately; use SDL3 mapping APIs and validate controller GUID/layout; no database copied'},
        {'component': 'D3D12/DXGI/XAudio/XInput and VC runtime DLLs', 'archive_payload': 'OS/runtime dependencies',
         'native_reuse': 'Use installed platform runtimes; no DLL copying from the Xenia package is possible'},
        {'component': 'LICENSE', 'archive_payload': 'BSD 3-Clause notice present and preserved',
         'native_reuse': 'Retain source/binary notices for actual code reuse and relevant third-party notices'}
    ],
    'original_files_preserved': all(sha(p) == original_hashes[p.name] for p in (exe, archive, license_file)),
    'claims_not_established': ['emulator boot', 'native renderer correctness', '1920x1080 image quality', '120FPS gameplay/physics correctness']
}
output = reports / 'xenia-dependencies.json'
output.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps({'status': report['status'], 'commit': commit, 'archive_verified': report['official_release']['archive_hash_matches'],
                  'imports': len(imports), 'exports': [e['name'] for e in exports], 'report': str(output)}, ensure_ascii=False))
raise SystemExit(0 if report['status'] == 'PASS' else 2)
