"""Offline regression tests for publication safety and recovery."""
import io
from contextlib import redirect_stdout
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from harmony_apptest import (ApiRejected, BUNDLE, Publication, ReleaseError,
                             check_response, language_update, package_info,
                             print_status, select_group, test_information, verify_remote_configuration)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'publication.json'
        self.identity = {'sha256': 'original', 'groupId': 'internal', 'notes': 'Feature'}

    def test_uncertain_submission_cannot_be_automatically_retried(self):
        state = Publication(self.path, self.identity)
        def timeout_after_server_accepts():
            raise TimeoutError()
        with self.assertRaises(TimeoutError):
            state.mutation('submitted', timeout_after_server_accepts)
        with self.assertRaisesRegex(ReleaseError, 'Uncertain previous submitted'):
            Publication(self.path, self.identity)

    def test_explicit_rejection_can_be_corrected_and_retried(self):
        state = Publication(self.path, self.identity)
        def reject():
            raise ApiRejected('Validation failed')
        with self.assertRaises(ApiRejected):
            state.mutation('versionId', reject)
        resumed = Publication(self.path, self.identity)
        self.assertEqual(resumed.mutation('versionId', lambda: 'version-20'), 'version-20')

    def test_confirmed_creation_is_reused_after_restart(self):
        state = Publication(self.path, self.identity)
        state.mutation('versionId', lambda: 'version-20')
        resumed = Publication(self.path, self.identity)
        self.assertEqual(resumed.mutation('versionId', lambda: self.fail('duplicate POST')), 'version-20')

    def test_changed_artifact_group_or_notes_cannot_reuse_state(self):
        Publication(self.path, self.identity).save()
        for key in self.identity:
            with self.subTest(key=key), self.assertRaisesRegex(ReleaseError, 'inputs changed'):
                Publication(self.path, {**self.identity, key: 'changed'})

    def test_selecting_external_or_ambiguous_group_is_rejected(self):
        internal = {'groupId': 'i', 'groupName': '内部测试', 'groupType': 1}
        external = {'groupId': 'e', 'groupName': '外部测试', 'groupType': 0}
        self.assertEqual(select_group([internal, external], '内部测试'), internal)
        for groups, name in [([external], '外部测试'), ([internal, internal], '内部测试'), ([internal], 'missing')]:
            with self.subTest(name=name), self.assertRaises(ReleaseError):
                select_group(groups, name)
        info = test_information(internal, 'Feature', 1000, 2000)
        self.assertEqual(info['testTaskInfo']['groupInfos'][0]['bind'], 1)
        self.assertEqual(info['testTaskInfo']['needShareLink'], 0)
        self.assertEqual(info['testTaskInfo']['needNotify'], 0)

    def test_http_success_does_not_hide_api_failure(self):
        for data in [{'ret': {'code': 403, 'msg': 'denied'}}, {'rtnCode': 2, 'rtnDesc': 'denied'}]:
            with self.subTest(data=data), self.assertRaises(ApiRejected):
                check_response(data)
        with self.assertRaises(ReleaseError):
            check_response({})
        self.assertEqual(check_response({'rtnCode': '0'})['rtnCode'], '0')

    def test_notes_update_preserves_required_existing_description(self):
        language = {'lang': 'zh-CN', 'appName': 'Reader', 'appDesc': 'Existing description',
                    'briefInfo': 'Reader brief', 'newFeatures': 'Old notes'}
        result = language_update([language], 'New notes')
        self.assertEqual(result['appDesc'], language['appDesc'])
        self.assertEqual(result['appName'], language['appName'])
        self.assertEqual(result['language'], 'zh-CN')
        self.assertEqual(result['newFeatures'], 'New notes')
        with self.assertRaises(ReleaseError):
            language_update([{'lang': 'zh-CN'}], 'New notes')

    def test_remote_binding_must_confirm_the_intended_package_and_group(self):
        info = {'versionName': '1.0.0', 'versionCode': 20}
        result = {'appInfo': {'versionNumber': '1.0.0', 'versionCode': 20},
                  'languages': [{'lang': 'zh-CN', 'newFeatures': 'Feature'}],
                  'openTestInfo': {'testTaskInfo': {'groupInfos': [{'groupId': 'i', 'bind': 1}]}}}
        verify_remote_configuration(result, info, 'i', 'Feature')
        result['openTestInfo']['testTaskInfo']['groupInfos'].append({'groupId': 'external', 'bind': 1})
        with self.assertRaisesRegex(ReleaseError, 'only the selected internal group'):
            verify_remote_configuration(result, info, 'i', 'Feature')

    def test_status_uses_current_details_instead_of_stale_list_state(self):
        class Client:
            def versions(self):
                return [{'versionId': 'v20', 'state': 7, 'releaseType': 6}]

            def version_info(self, version_id):
                return {'appInfo': {'releaseState': 12, 'testUserPassword': 'do-not-print'}}

        output = io.StringIO()
        with redirect_stdout(output):
            print_status(Client())
        result = json.loads(output.getvalue())[0]
        self.assertEqual(result['releaseState'], 12)
        self.assertEqual(result['status'], '预审中')
        self.assertNotIn('do-not-print', output.getvalue())

    def make_package(self, *, debug=False, bundle=BUNDLE, code=20):
        hap_bytes = io.BytesIO()
        with zipfile.ZipFile(hap_bytes, 'w') as hap:
            hap.writestr('module.json', json.dumps({'app': {
                'bundleName': bundle, 'versionName': '1.0.0', 'versionCode': code,
                'debug': debug, 'buildMode': 'release',
            }}))
        path = Path(self.temporary.name) / 'sample.app'
        with zipfile.ZipFile(path, 'w') as package:
            package.writestr('entry.hap', hap_bytes.getvalue())
            package.writestr('pack.info', json.dumps({'summary': {'app': {
                'bundleName': BUNDLE, 'version': {'name': '1.0.0', 'code': 20},
            }}}))
        return path

    def test_rejects_debug_wrong_bundle_or_inconsistent_hap(self):
        self.assertEqual(package_info(self.make_package())['versionCode'], 20)
        for kwargs in [{'debug': True}, {'bundle': 'com.example.other'}, {'code': 19}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ReleaseError):
                package_info(self.make_package(**kwargs))


if __name__ == '__main__':
    unittest.main()
