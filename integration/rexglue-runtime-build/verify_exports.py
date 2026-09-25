"""Compare the new runtime with the original and exact local consumers."""
from pathlib import Path
import hashlib
import json
import pefile

# ReXGlue exports more than 8192 symbols and some decorated C++ names exceed
# pefile's 512-byte defensive defaults. Parse the actual complete PE tables.
pefile.MAX_SYMBOL_NAME_LENGTH = 65536
pefile.MAX_IMPORT_NAME_LENGTH = 65536

here = Path(__file__).resolve().parent
workspace = here.parents[1]
original = workspace / 'win-amd64/bin/rexruntimerd.dll'
replacement = here / 'build/bin/rexruntimerd.dll'
host_dir = workspace / 'cod3-pc/out/build/win-amd64-relwithdebinfo'

def exports(path):
    with pefile.PE(str(path), fast_load=True, max_symbol_exports=65536) as pe:
        pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']])
        if len(pe.DIRECTORY_ENTRY_EXPORT.symbols) != pe.DIRECTORY_ENTRY_EXPORT.struct.NumberOfFunctions:
            raise RuntimeError(f'Incomplete export parse for {path}')
        return {symbol.name.decode('ascii'): symbol.ordinal
                for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols if symbol.name}

old = exports(original)
new = exports(replacement)
consumer_paths = sorted(set(list(host_dir.glob('*.exe')) + list(host_dir.glob('*.dll')) +
                            [here / 'probe-build/runtime_heap_abi_probe.exe']))
consumers = []
for path in consumer_paths:
    with pefile.PE(str(path), fast_load=True) as pe:
        pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
        for entry in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', []):
            if entry.dll.decode('ascii').lower() != 'rexruntimerd.dll':
                continue
            names = [symbol.name.decode('ascii') for symbol in entry.imports if symbol.name]
            ordinals = [symbol.ordinal for symbol in entry.imports if not symbol.name]
            consumers.append({'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'named_imports': len(names),
                              'ordinal_imports': ordinals,
                              'missing_names': sorted(set(names) - new.keys())})

report = {
    'configuration': 'RelWithDebInfo',
    'original': str(original), 'replacement': str(replacement),
    'original_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
    'replacement_sha256': hashlib.sha256(replacement.read_bytes()).hexdigest(),
    'old_export_count': len(old), 'new_export_count': len(new),
    'removed_exports': sorted(old.keys() - new.keys()),
    'added_exports': sorted(new.keys() - old.keys()),
    'consumer_imports': consumers,
    'consumer_coverage_pass': all(not c['missing_names'] and not c['ordinal_imports'] for c in consumers),
    'scope': 'Names required by current local host/modules/plugin and original-SDK probe; not a proof of every runtime contract.'
}
(here / 'export-comparison.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
print(json.dumps({key: report[key] for key in ('old_export_count', 'new_export_count', 'consumer_coverage_pass')}) )
print(f"removed={len(report['removed_exports'])}; added={len(report['added_exports'])}; consumers={len(consumers)}")
if not report['consumer_coverage_pass']:
    print(json.dumps([c for c in consumers if c['missing_names'] or c['ordinal_imports']], indent=2))
    raise SystemExit(1)
