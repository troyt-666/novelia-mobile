#!/usr/bin/env python3
"""Run Flutter OHOS in an ignored copy with an OHOS-compiled SQLite library."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

app = Path(__file__).resolve().parents[1]
work = app / 'build' / 'harmony'
stage = work / 'app'
sdk = Path(os.environ['DEVECO_SDK_HOME']) / 'default' / 'openharmony'
if not (sdk / 'native' / 'sysroot').is_dir():
    sys.exit('DEVECO_SDK_HOME must point to the HarmonyOS SDK directory.')
work.mkdir(parents=True, exist_ok=True)

# Canary 1 omits the native-assets manifest from the HAP. Apply the small
# upstream-style fix only to the independent OHOS SDK when it is still needed.
flutter = Path(shutil.which('flutter') or sys.exit('Flutter OHOS is not on PATH.')).resolve()
flutter_sdk = flutter.parents[1]
target = flutter_sdk / 'packages/flutter_tools/lib/src/build_system/targets/ohos.dart'
if not target.exists():
    sys.exit('Use the independent Flutter OHOS SDK, not the standard Flutter SDK.')
if 'NativeAssetsManifest.json' not in target.read_text():
    patch = str(app / 'tool' / 'flutter_ohos_native_assets.patch')
    subprocess.run(['git', 'apply', '--check', patch], cwd=flutter_sdk, check=True)
    subprocess.run(['git', 'apply', patch], cwd=flutter_sdk, check=True)
    (flutter_sdk / 'bin/cache/flutter_tools.stamp').unlink(missing_ok=True)

# sqlite3's upstream hook sees OHOS as Linux in this Flutter fork. Its default
# prebuilt library uses the wrong ABI, so compile the official source instead.
sqlite = work / 'sqlite3.c'
if not sqlite.exists():
    archive = work / 'sqlite.zip'
    subprocess.run(['curl', '-fL', '--retry', '2', '-o', str(archive),
                    'https://sqlite.org/2026/sqlite-amalgamation-3530400.zip'], check=True)
    expected = '628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e'
    if hashlib.sha3_256(archive.read_bytes()).hexdigest() != expected:
        sys.exit('SQLite source checksum did not match the published SHA3-256.')
    with zipfile.ZipFile(archive) as source:
        sqlite.write_bytes(source.read('sqlite-amalgamation-3530400/sqlite3.c'))

# Keep private signing material in the ignored build copy. The source project
# always contains an empty signingConfigs array.
profile = stage / 'ohos' / 'build-profile.json5'
signing = []
if profile.exists():
    cli = Path(shutil.which('devecocli') or sys.exit('DevEco CLI is not on PATH.')).resolve()
    # Reuse the JSON5 parser shipped with DevEco CLI for its generated profile.
    signing = json.loads(subprocess.check_output([
        'node', '-e', "const fs = require('node:fs'); "
        "const load = require('node:module').createRequire(process.argv[1]); "
        "process.stdout.write(JSON.stringify(load('json5').parse("
        "fs.readFileSync(process.argv[2], 'utf8')).app.signingConfigs));",
        str(cli), str(profile)], text=True))
subprocess.run(['rsync', '-a', '--delete',
                '--exclude=build/', '--exclude=.dart_tool/', '--exclude=.git/',
                '--exclude=oh_modules/', '--exclude=node_modules/',
                '--exclude=.hvigor/', '--exclude=.cxx/', '--exclude=Pods/',
                '--exclude=.symlinks/', '--exclude=ephemeral/',
                str(app) + '/', str(stage) + '/'], check=True)
profile.write_text(profile.read_text().replace(
    '"signingConfigs": []', '"signingConfigs": ' + json.dumps(signing)))
manifest = stage / 'pubspec.yaml'
manifest.write_text(manifest.read_text() + '\nhooks:\n  user_defines:\n    sqlite3:\n'
                    '      source: source\n'
                    f'      path: {json.dumps(str(sqlite))}\n'
                    '      additional_flags:\n'
                    '        - --target=aarch64-linux-ohos\n'
                    f'        - {json.dumps("--sysroot=" + str(sdk / "native" / "sysroot"))}\n'
                    '      additional_libraries: [m]\n')
subprocess.run(['flutter', 'pub', 'get'], cwd=stage, check=True)
command = sys.argv[1:] or ['build', 'hap', '--debug']
if not signing and '--no-codesign' not in command:
    subprocess.run(['devecocli', 'signature', 'generate'], cwd=stage / 'ohos', check=True)
subprocess.run(['flutter', *command], cwd=stage, check=True)
