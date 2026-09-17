#!/usr/bin/env python3
"""Build and publish JFZ Reader using Huawei's documented Connect/Testing APIs.

Python standard library, Node (PS256), Java and the existing HarmonyOS SDK only.
Credentials stay outside the checkout. See docs/harmonyos-apptest.md.
"""
import argparse
from datetime import datetime, timedelta
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

APP = Path(__file__).resolve().parents[1]
REPO = APP.parent
APP_ID = '6917616114030016453'
BUNDLE = 'io.github.troyt666.jfzreader.hm'
API = 'https://connect-api.cloud.huawei.com'
PRIVATE = Path.home() / 'development/jfzreader-signing'
DEFAULT_CREDENTIAL = PRIVATE / 'agc-service-account.json'
SIGNING = PRIVATE / 'harmony-release'
TEST_STATES = {0: '正在测试', 1: '审核不通过', 2: '已失效（运营停止测试）',
               3: '待生效', 4: '正在审核', 7: '准备提交', 10: '已失效（开发者停止测试）',
               11: '撤销审核', 12: '预审中', 13: '预审不通过'}


class ReleaseError(Exception):
    pass


class ApiRejected(ReleaseError):
    """An explicit API rejection, as opposed to an uncertain network outcome."""


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    temporary.replace(path)


def source_version():
    manifest = (APP / 'pubspec.yaml').read_text()
    match = re.search(r'^version:\s*([\d.]+)\+(\d+)\s*$', manifest, re.M)
    if not match:
        raise ReleaseError('Expected a version such as 1.0.0+20 in pubspec.yaml.')
    name, code = match[1], int(match[2])
    harmony = json.loads((APP / 'ohos/AppScope/app.json5').read_text())['app']
    if (harmony['versionName'], harmony['versionCode'], harmony['bundleName']) != (name, code, BUNDLE):
        raise ReleaseError('Flutter and HarmonyOS versions/package name do not match.')
    return name, code


def package_info(path):
    with zipfile.ZipFile(path) as app_zip:
        summary = json.loads(app_zip.read('pack.info'))['summary']['app']
        if summary['bundleName'] != BUNDLE:
            raise ReleaseError('Refusing a package with a different bundle name.')
        haps = [n for n in app_zip.namelist() if n.endswith('.hap')]
        if not haps:
            raise ReleaseError('APP contains no HAP.')
        for hap in haps:
            with zipfile.ZipFile(io.BytesIO(app_zip.read(hap))) as hap_zip:
                app = json.loads(hap_zip.read('module.json'))['app']
                if app.get('debug') is not False or app.get('buildMode') != 'release':
                    raise ReleaseError('Refusing to publish a debug HAP.')
                if (app['bundleName'], app['versionName'], app['versionCode']) != (
                    BUNDLE, summary['version']['name'], summary['version']['code']
                ):
                    raise ReleaseError('APP and HAP metadata disagree.')
    with path.open('rb') as stream:
        sha256 = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {
        'versionName': summary['version']['name'],
        'versionCode': summary['version']['code'],
        'size': path.stat().st_size,
        'sha256': sha256,
    }


def signing_tool():
    sdk = os.environ.get('DEVECO_SDK_HOME')
    if not sdk:
        raise ReleaseError('Source ~/development/harmony-env.sh first.')
    return Path(sdk) / 'default/openharmony/toolchains/lib/hap-sign-tool.jar'


def run_signer(arguments, log_path, password_file=None):
    jar = signing_tool()
    with tempfile.TemporaryDirectory(prefix='jfz-sign-') as temporary:
        if password_file:
            # Read the password inside Java, keeping it out of process arguments.
            launcher = Path(temporary) / 'PrivateSign.java'
            launcher.write_text('''
import java.nio.file.*;
import java.util.*;
class PrivateSign {
  public static void main(String[] args) throws Exception {
    String password = Files.readString(Path.of(args[0])).strip();
    var options = new ArrayList<String>(Arrays.asList(args).subList(1, args.length));
    options.addAll(List.of("-keystorePwd", password, "-keyPwd", password));
    com.ohos.hapsigntool.HapSignTool.main(options.toArray(new String[0]));
  }
}
''')
            command = ['java', '--class-path', str(jar), str(launcher), str(password_file), *arguments]
        else:
            command = ['java', '-jar', str(jar), *arguments]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout.decode(errors='replace')
        if password_file:
            output = output.replace(password_file.read_text().strip(), '[redacted]')
        log_path.write_text(output)
        if result.returncode or 'ERROR' in output:
            raise ReleaseError(f'Signing/verification failed; see {log_path}.')
        return output


def verify_package(path):
    info = package_info(path)
    with tempfile.TemporaryDirectory(prefix='jfz-verify-') as temporary:
        directory = Path(temporary)
        output = run_signer(['verify-app', '-inFile', str(path),
                             '-outCertChain', str(directory / 'chain.cer'),
                             '-outProfile', str(directory / 'profile.p7b')],
                            path.with_suffix('.verify.log'))
        if 'verify-app success' not in output.lower():
            raise ReleaseError('Signing tool did not confirm signature verification.')
        # The release Profile is what distinguishes this AppTest install from
        # the earlier device-bound debug install with the same bundle name.
        if (directory / 'profile.p7b').read_bytes() != (SIGNING / 'jfzreader-release.p7b').read_bytes():
            raise ReleaseError('APP was not signed with the configured AppTest release Profile.')
    return info


def build(skip_build=False):
    name, code = source_version()
    directory = APP / 'build' / f'apptest-{code}'
    directory.mkdir(parents=True, exist_ok=True)
    if not skip_build:
        with (directory / 'build.log').open('w') as log:
            result = subprocess.run([sys.executable, str(APP / 'tool/flutter_harmony.py'),
                                     'build', 'app', '--release', '--no-codesign'],
                                    cwd=APP, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ReleaseError(f'Build failed; see {directory / "build.log"}.')
    unsigned = APP / 'build/harmony/app/build/ohos/app/ohos-default-unsigned.app'
    metadata = package_info(unsigned)
    if (metadata['versionName'], metadata['versionCode']) != (name, code):
        raise ReleaseError('Build output is stale; build the current version first.')
    signed = directory / f'JFZ-Reader-{name}-{code}-AppTest.app'
    if (directory / 'publication.json').exists():
        raise ReleaseError('This build has publication state; do not replace its signed artifact.')
    run_signer(['sign-app', '-mode', 'localSign', '-keyAlias', 'jfzreader-release',
                '-appCertFile', str(SIGNING / 'jfzreader-release.cer'),
                '-profileFile', str(SIGNING / 'jfzreader-release.p7b'),
                '-keystoreFile', str(SIGNING / 'jfzreader-release.p12'),
                '-signAlg', 'SHA256withECDSA', '-compatibleVersion', '18',
                '-inFile', str(unsigned), '-outFile', str(signed)],
               directory / 'sign.log', SIGNING / 'keystore-password.txt')
    info = verify_package(signed)
    write_json(directory / 'artifact.json', {'package': str(signed), **info})
    print(json.dumps({'package': str(signed), **info}, ensure_ascii=False, indent=2))
    return signed


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_response(data):
    if 'ret' in data:
        code, message = data['ret'].get('code'), data['ret'].get('msg', '')
    elif 'rtnCode' in data:
        code, message = data['rtnCode'], data.get('rtnDesc', '')
    else:
        raise ReleaseError('API response has no documented success indicator.')
    if str(code) != '0':
        raise ApiRejected(f'AGC rejected request ({code}): {message[:300]}')
    return data


class Connect:
    def __init__(self, credential):
        credential = credential.expanduser().resolve()
        if credential.is_relative_to(REPO):
            raise ReleaseError('Store the service account credential outside the repository.')
        if credential.stat().st_mode & 0o077:
            raise ReleaseError('Credential permissions must be 600 (chmod 600 <credential>).')
        self.credential = credential
        self.opener = urllib.request.build_opener(NoRedirect())

    def token(self):
        # Node ships with the HarmonyOS toolchain; no extra Python packages needed.
        script = '''
const fs = require('node:fs'), crypto = require('node:crypto');
const k = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const enc = v => Buffer.from(JSON.stringify(v)).toString('base64url');
const now = Math.floor(Date.now()/1000);
const unsigned = enc({kid:k.key_id,typ:'JWT',alg:'PS256'}) + '.' +
  enc({aud:'https://oauth-login.cloud.huawei.com/oauth2/v3/token',iss:k.sub_account,iat:now,exp:now+3600});
const sig = crypto.sign('sha256', Buffer.from(unsigned),
  {key:k.private_key,padding:crypto.constants.RSA_PKCS1_PSS_PADDING,saltLength:32});
process.stdout.write(unsigned + '.' + sig.toString('base64url'));
'''
        result = subprocess.run(['node', '-e', script, str(self.credential)],
                                capture_output=True, text=True)
        if result.returncode:
            raise ReleaseError('Could not sign service account JWT; check Node and the credential file.')
        return result.stdout

    def request(self, method, path, body=None, **query):
        url = API + path + ('?' + urllib.parse.urlencode(query) if query else '')
        data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            'Authorization': 'Bearer ' + self.token(), 'appId': APP_ID,
            'Content-Type': 'application/json',
        })
        try:
            with self.opener.open(request, timeout=90) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            # Do not print request headers, JWTs, or signed upload URLs.
            raise ReleaseError(f'AGC HTTP {error.code} for {path}; outcome may need reconciliation.') from None
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise ReleaseError(f'AGC transport/response failure ({type(error).__name__}) for {path}.') from None
        return check_response(result)

    def groups(self):
        groups, page = [], 1
        while True:
            result = self.request('GET', '/api/app-test/v1/test-group/list',
                                  groupType=1, current=page, pageSize=100)
            groups.extend(result.get('groups', []))
            if page >= int(result.get('pageInfo', {}).get('totalPage', 1)):
                return groups
            page += 1

    def versions(self):
        return self.request('POST', '/api/publish/v3/version/brief-info/list',
                            {'packageName': BUNDLE})['versionList']

    def version_info(self, version_id):
        return self.request('GET', '/api/publish/v3/app-info', appId=APP_ID,
                            releaseType=6, versionId=version_id)

    def upload(self, path, info):
        result = self.request('GET', '/api/publish/v2/upload-url/for-obs',
                              appId=APP_ID, fileName=path.name,
                              sha256=info['sha256'], contentLength=info['size'],
                              chineseMainlandFlag=1)['urlInfo']
        destination = urllib.parse.urlsplit(result['url'])
        if destination.scheme != 'https' or not destination.hostname or destination.username:
            raise ReleaseError('AGC returned an invalid upload destination.')
        if result['method'] != 'PUT':
            raise ReleaseError('AGC returned an unexpected upload method.')
        # Only use the upload-specific headers. Never forward the Connect JWT.
        headers = dict(result['headers'])
        headers['Content-Length'] = str(info['size'])
        try:
            with path.open('rb') as stream:
                request = urllib.request.Request(result['url'], data=stream,
                                                 method='PUT', headers=headers)
                with self.opener.open(request, timeout=180) as response:
                    if response.status != 200:
                        raise ReleaseError('Upload did not return HTTP 200.')
        except (urllib.error.URLError, TimeoutError):
            raise ReleaseError('Package upload failed; signed upload URL omitted from logs.') from None
        return result['objectId']


class Publication:
    """Checkpoint confirmed outcomes; never blindly retry an ambiguous POST."""
    def __init__(self, path, identity):
        self.path = path
        self.data = json.loads(path.read_text()) if path.exists() else {'identity': identity}
        if self.data['identity'] != identity:
            raise ReleaseError('Publication inputs changed; retain the original package, notes and group.')
        if self.data.get('pending'):
            raise ReleaseError(f'Uncertain previous {self.data["pending"]} request. '
                               'Inspect AGC before reconciling publication.json; do not retry blindly.')

    def save(self):
        write_json(self.path, self.data)

    def mutation(self, key, action):
        if key in self.data:
            return self.data[key]
        self.data['pending'] = key
        self.save()
        try:
            value = action()
        except ApiRejected:
            self.data.pop('pending')
            self.save()
            raise
        self.data[key] = value
        self.data.pop('pending')
        self.save()
        return value


def test_information(group, description, start, end):
    return {
        'startTime': start, 'endTime': end, 'testDesc': description,
        'testTaskInfo': {
            'groupInfos': [{'groupId': group['groupId'], 'groupName': group['groupName'],
                            'addedTesterNum': group.get('addedTestersNum', 0), 'bind': 1}],
            'needShareLink': 0, 'displayArea': '1', 'needNotify': 0,
        },
    }


def language_update(languages, notes):
    matches = [language for language in languages if language.get('lang') == 'zh-CN']
    if len(matches) != 1 or not matches[0].get('appDesc'):
        raise ReleaseError('The new test version did not inherit its Chinese app description.')
    language = matches[0]
    return {'language': 'zh-CN', 'appDesc': language['appDesc'],
            **{key: language[key] for key in ('appName', 'briefInfo') if key in language},
            'newFeatures': notes}


def verify_remote_configuration(result, info, group_id, notes):
    app_info = result['appInfo']
    if (app_info.get('versionNumber'), int(app_info.get('versionCode', -1))) != (
        info['versionName'], info['versionCode']
    ):
        raise ReleaseError('AGC has not bound the expected package version.')
    test_info = result.get('openTestInfo', {}).get('testTaskInfo', {})
    bound = [str(group['groupId']) for group in test_info.get('groupInfos', [])
             if int(group.get('bind', 0)) == 1]
    if bound != [str(group_id)]:
        raise ReleaseError('AGC has not confirmed only the selected internal group is bound.')
    languages = result.get('languages', [])
    if not any(l.get('lang') == 'zh-CN' and l.get('newFeatures') == notes for l in languages):
        raise ReleaseError('AGC release notes did not match the requested text.')


def wait_for_package(client, package_id, timeout):
    deadline = time.monotonic() + timeout
    while True:
        result = client.request('GET', '/api/publish/v3/package/compile/status',
                                appId=APP_ID, pkgIds=package_id)
        states = result['pkgStateList']
        matching = [s for s in states if str(s['pkgId']) == package_id]
        if len(matching) == 1 and matching[0].get('successStatus') == 0:
            print('AGC package parsing completed.', flush=True)
            return
        print('AGC package parsing: ' + json.dumps(matching, ensure_ascii=False), flush=True)
        if time.monotonic() >= deadline:
            raise ReleaseError('Package parsing is not ready; rerun the same publish command later.')
        time.sleep(min(15, max(0, deadline - time.monotonic())))


def publish(client, path, notes, group_name, timeout):
    path = path.resolve()
    info = verify_package(path)
    if (info['versionName'], info['versionCode']) != source_version():
        raise ReleaseError('Package version does not match the source manifests.')
    if not 1 <= len(notes) <= 1000:
        raise ReleaseError('Release notes must contain 1–1000 characters.')
    group = select_group(client.groups(), group_name)
    identity = {'appId': APP_ID, **info, 'notes': notes, 'groupId': group['groupId']}
    state_path = path.parent / 'publication.json'
    lock_path = path.parent / 'publication.lock'
    with lock_path.open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError('Another publish command is already running for this package.') from None
        state = Publication(state_path, identity)
        if state.data.get('submitted'):
            print(f'Already submitted version {state.data["versionId"]}; no changes made.')
            print_status(client, state.data['versionId'])
            return
        versions = client.versions()
        for version in versions:
            if any(int(p.get('versionCode', -1)) == info['versionCode']
                   for p in version.get('packageList', [])):
                if str(version['versionId']) != state.data.get('versionId'):
                    raise ReleaseError('AGC already has this build number in another version. '
                                       'Inspect it before creating a duplicate.')
        if 'objectId' not in state.data:
            print('Uploading signed APP to AGC…', flush=True)
            # A repeated standalone object upload cannot create a test version.
            state.data['objectId'] = client.upload(path, info)
            state.save()
        package_id = state.mutation('packageId', lambda: str(client.request(
            'POST', '/api/publish/v2/test/version/pkg',
            {'distributeMode': 1, 'file': {'fileName': path.name,
                                         'objectId': state.data['objectId']}},
            appId=APP_ID)['pkgVersion'][0]))
        wait_for_package(client, package_id, timeout)
        description = f'{info["versionName"]}（{info["versionCode"]}）{notes}'[:50]
        version_id = state.mutation('versionId', lambda: str(client.request(
            'POST', '/api/publish/v2/test/app/version',
            {'releaseType': 6, 'testType': 3, 'testDesc': description, 'onshelfSelfDetect': 0},
            appId=APP_ID)['versionId']))
        if 'testInfo' not in state.data:
            start = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
            end = start + timedelta(days=89, hours=23, minutes=59, seconds=59)
            state.data['testInfo'] = test_information(group, description,
                                                     int(start.timestamp()*1000), int(end.timestamp()*1000))
            state.save()
        inherited = client.version_info(version_id)
        language = language_update(inherited['languages'], notes)
        state.mutation('configured', lambda: client.request(
            'PUT', '/api/publish/v2/test/app/version',
            {'versionId': version_id, 'pkgId': package_id,
             'languages': [language],
             'openTestInfo': state.data['testInfo']}, appId=APP_ID))
        verify_remote_configuration(client.version_info(version_id), info, group['groupId'], notes)
        print(f'Submitting internal test version {version_id}…', flush=True)
        state.mutation('submitted', lambda: client.request(
            'POST', '/api/publish/v2/test/app/version/submit',
            {'versionId': version_id}, appId=APP_ID))
        print(f'AGC accepted submission. Version ID: {version_id}. Huawei processing is still separate.', flush=True)
        print_status(client, version_id)


def print_status(client, version_id=None):
    versions = client.versions()
    if version_id:
        versions = [v for v in versions if str(v['versionId']) == version_id]
        if not versions:
            raise ReleaseError('Requested version was not returned by AGC.')
    if version_id:
        details = client.version_info(version_id)
        app_info = details.get('appInfo', {})
        # AppInfo also contains account contact details; never print it wholesale.
        print(json.dumps({'versions': versions,
                          'status': TEST_STATES.get(app_info.get('releaseState'), '未知状态'),
                          'review': {key: app_info.get(key) for key in
                                     ('releaseState', 'reviewState', 'releaseTime', 'encrypted')},
                          'auditOpinion': details.get('auditInfo', {}).get('auditOpinion'),
                          'testInfo': details.get('openTestInfo')}, ensure_ascii=False, indent=2))
    else:
        # AppTest's list can remain at state=7 even after submission/approval.
        # Use the version-detail releaseState as the current test status.
        for version in versions:
            if version.get('releaseType') == 6:
                app_info = client.version_info(str(version['versionId'])).get('appInfo', {})
                version['releaseState'] = app_info.get('releaseState')
                version['status'] = TEST_STATES.get(app_info.get('releaseState'), '未知状态')
        print(json.dumps(versions, ensure_ascii=False, indent=2))


def select_group(groups, name):
    matches = [g for g in groups if name in (g['groupId'], g['groupName'])]
    if len(matches) != 1 or int(matches[0].get('groupType', -1)) != 1:
        raise ReleaseError('Select exactly one existing internal group by name or ID.')
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, default=DEFAULT_CREDENTIAL)
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build', help='Build, release-sign and verify the APP.')
    builder.add_argument('--skip-build', action='store_true', help='Sign existing matching build output.')
    commands.add_parser('groups', help='List existing internal test groups (read-only).')
    publisher = commands.add_parser('publish', help='Upload and submit to one existing internal group.')
    publisher.add_argument('--package', type=Path, required=True)
    publisher.add_argument('--notes-file', type=Path, required=True)
    publisher.add_argument('--group', default='内部测试')
    publisher.add_argument('--parse-timeout', type=int, default=300)
    status = commands.add_parser('status', help='Query version state without modifying AGC.')
    status.add_argument('--version-id')
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args.skip_build)
        elif args.command == 'groups':
            print(json.dumps(Connect(args.credentials).groups(), ensure_ascii=False, indent=2))
        elif args.command == 'publish':
            publish(Connect(args.credentials), args.package, args.notes_file.read_text().strip(),
                    args.group, args.parse_timeout)
        elif args.command == 'status':
            print_status(Connect(args.credentials), args.version_id)
    except (ReleaseError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(f'Error: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
