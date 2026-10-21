"""Offline failure injection: release completion must never be inferred from a push."""
from copy import deepcopy
from io import BytesIO
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlparse, parse_qs
from zipfile import ZipFile

import pipeline as p


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def zipped(files):
    out = BytesIO()
    with ZipFile(out, 'w') as z:
        for name, value in files.items():
            z.writestr(name, value)
    return out.getvalue()


def fixture(site):
    version = '2.4.3'
    fixed = site / 'releases/course/v2.4.3'
    fixed.mkdir(parents=True)
    info = {'version': version, 'gitTag': 'course-v' + version}
    skill = zipped({'SKILL.md': b'fixture'})
    bundle = {'profile': 'generic', 'files': {'VERSION.json': p.digest(encoded(info))},
              'skills': {'fixture': {'archive': 'fixture-skill.zip', 'sha256': p.digest(skill), 'files': {'SKILL.md': p.digest(b'fixture')}, 'requires': []}}}
    archive = zipped({'VERSION.json': encoded(info), 'bundle-manifest.json': encoded(bundle), 'fixture-skill.zip': skill})
    files = {'VERSION.json': encoded(info), 'ai-coding-toolkit.zip': archive,
             'ai-coding-toolkit.sha256': (p.digest(archive) + '  ai-coding-toolkit.zip\n').encode(),
             'fixture-skill.zip': skill, 'fixture-skill.sha256': (p.digest(skill) + '  fixture-skill.zip\n').encode()}
    files['manifest.json'] = encoded({'version': version, 'files': {n: p.digest(b) for n, b in files.items()}})
    manifest = {'version': version, 'status': 'release', 'baseUrl': p.PUBLIC + '/releases/course/v' + version,
                'profiles': {'generic': {'archive': 'ai-coding-toolkit.zip', 'sha256': p.digest(archive), 'bundleManifestSha256': p.digest(encoded(bundle)), 'bundle': bundle}},
                'files': {n: p.digest(b) for n, b in files.items()}}
    files['release-manifest.json'] = encoded(manifest)
    for name, value in files.items(): (fixed / name).write_bytes(value)
    (site / 'VERSION.json').write_bytes(encoded(info))
    (site / 'ai-coding-toolkit.zip').write_bytes(archive)
    (site / 'setup-guide.md').write_text('Get-CourseMaterials.ps1 Update-CourseMaterials.ps1 release-index.json CourseVersion -Action Check -Action Apply', encoding='utf-8')
    entry = {'status': 'release', 'baseUrl': manifest['baseUrl'], 'manifestUrl': manifest['baseUrl'] + '/release-manifest.json', 'manifestSha256': p.digest(files['release-manifest.json'])}
    (site / 'release-index.json').write_bytes(encoded({'latest': version, 'versions': {version: entry}}))
    for name in ('Get-CourseMaterials.ps1', 'Update-CourseMaterials.ps1', 'preparation.html', 'course/course-steps.json'):
        path = site / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture', encoding='utf-8')
    publication = {'version': version, 'status': 'release', 'files': {x.relative_to(site).as_posix(): p.digest(x.read_bytes()) for x in site.rglob('*') if x.is_file()}}
    (site / 'publication.json').write_bytes(encoded(publication))
    (site / '.release').mkdir()
    (site / '.release/request.json').write_bytes(encoded({'version': version, 'publicationSha256': p.digest(encoded(publication)), 'notes': 'fixture'}))
    subprocess.run(['git', 'init', '-b', 'main', str(site)], check=True, stdout=subprocess.DEVNULL)
    p.git(site, 'config', 'core.autocrlf', 'false')
    p.git(site, 'add', '.')
    p.git(site, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')


class FakeGitHub:
    def __init__(self, commit):
        self.head = commit
        self.ref = None
        self.release = None
        self.latest_version = '2.4.2'
        self.mutations = []
        self.interrupt_upload = False

    def call(self, path, method='GET', data=None, missing=False, binary=False):
        if method != 'GET': self.mutations.append((path, method))
        if path == '/commits/main': return {'sha': self.head}
        if path.startswith('/git/ref/tags/'): return deepcopy(self.ref)
        if path == '/git/refs':
            self.ref = {'object': {'sha': data['sha'], 'type': 'commit'}}
            return deepcopy(self.ref)
        if path == '/releases/latest':
            if self.release and not self.release['draft'] and self.latest_version == '2.4.3': return deepcopy(self.release)
            return {'tag_name': 'course-v' + self.latest_version}
        if path.startswith('/releases/tags/'):
            return deepcopy(self.release) if self.release and not self.release['draft'] else None
        if path.startswith('/releases?'): return [deepcopy(self.release)] if self.release else []
        if path == '/releases' and method == 'POST':
            self.release = {**data, 'id': 1, 'assets': [], 'html_url': 'https://fixture.invalid/release', 'upload_url': 'https://uploads.github.com/repos/fixture/releases/1/assets{?name}'}
            return deepcopy(self.release)
        if path.startswith('https://uploads.github.com/'):
            if self.interrupt_upload and self.release['assets']:
                self.interrupt_upload = False
                raise p.ReleaseError('injected upload interruption')
            name = parse_qs(urlparse(path).query)['name'][0]
            asset = {'name': name, 'digest': 'sha256:' + p.digest(data), 'size': len(data)}
            self.release['assets'].append(asset)
            return deepcopy(asset)
        if path.startswith('/releases/assets/'):
            asset = next(a for a in self.release['assets'] if a.get('id') == int(path.rsplit('/', 1)[1]))
            if method == 'DELETE':
                self.release['assets'].remove(asset)
                return None
            return deepcopy(asset)
        if path == '/releases/1':
            if method == 'PATCH':
                self.release.update({k: v for k, v in data.items() if k != 'make_latest'})
                self.latest_version = '2.4.3'
            return deepcopy(self.release)
        raise AssertionError((path, method))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix='release-gates-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.site = self.base / 'site'; self.site.mkdir()
        fixture(self.site)
        p.atomic_json(self.base / 'preparation-verification.json', {
            'status': 'passed', 'freshVersion': '2.4.3', 'to': '2.4.3', 'from': '2.3.14'})
        self.api = FakeGitHub(p.git(self.site, 'rev-parse', 'HEAD'))
        self.runner = p.Runner(self.site, '2.4.3', self.base / 'report.json', github=self.api)

    def fetch(self, url):
        name = unquote(urlparse(url).path.removeprefix('/aicoding-course/'))
        return (self.site / name).read_bytes()

    def test_full_success_requires_public_checks(self):
        self.runner.check(); self.runner.prepare(); self.runner.verify_pages(self.fetch, attempts=1)
        with patch.object(p, 'GitHub', return_value=self.api): self.runner.finalize()
        self.assertEqual(p.read_json(self.base / 'report.json')['status'], 'success')

    def test_interrupted_upload_resumes_without_duplicate_tag_or_assets(self):
        self.api.interrupt_upload = True
        with self.assertRaises(p.ReleaseError): self.runner.prepare()
        self.runner.prepare()
        self.assertEqual(sum(path == '/git/refs' for path, method in self.api.mutations), 1)
        self.assertEqual(len(self.api.release['assets']), len(p.expected_assets(self.runner.checked)))

    def test_conflicting_attachment_is_preserved(self):
        self.runner.prepare()
        self.api.release['assets'][0]['digest'] = 'sha256:' + '0' * 64
        before = deepcopy(self.api.release['assets'])
        with self.assertRaisesRegex(p.ReleaseError, 'ASSET_MISMATCH'): self.runner.prepare()
        self.assertEqual(self.api.release['assets'], before)
        self.assertFalse(any(method == 'DELETE' for path, method in self.api.mutations))

    def test_pages_failure_prevents_latest(self):
        self.runner.check(); self.runner.prepare()
        with self.assertRaises(p.ReleaseError): self.runner.verify_pages(lambda url: b'old cached bytes', attempts=1)
        with self.assertRaisesRegex(p.ReleaseError, 'GATE_MISSING'): self.runner.finalize()
        self.assertEqual(self.api.latest_version, '2.4.2')
        self.assertTrue(self.api.release['draft'])

    def test_missing_gate_cannot_be_promoted(self):
        with self.assertRaisesRegex(p.ReleaseError, 'GATE_MISSING'): self.runner.finalize()
        self.assertFalse(any(method == 'PATCH' for path, method in self.api.mutations))

    def test_stale_checkout_cannot_create_tag(self):
        self.api.head = '0' * 40
        with self.assertRaisesRegex(p.ReleaseError, 'STALE_RELEASE'): self.runner.prepare()
        self.assertEqual(self.api.mutations, [])

    def test_latest_cannot_be_downgraded(self):
        self.runner.check(); self.runner.prepare(); self.runner.verify_pages(self.fetch, attempts=1)
        self.api.latest_version = '2.4.4'
        with self.assertRaisesRegex(p.ReleaseError, 'DOWNGRADE'): self.runner.finalize()

    def test_existing_tag_cannot_be_moved(self):
        self.runner.prepare()
        before = deepcopy(self.api.ref)
        target = self.site / 'releases/course/v2.4.3/release-manifest.json'
        target.write_bytes(b'changed')
        with self.assertRaisesRegex(p.ReleaseError, 'TAG_CONTENT_CHANGED'): self.runner.prepare()
        self.assertEqual(self.api.ref, before)

    def test_publication_tampering_is_rejected(self):
        (self.site / 'ai-coding-toolkit.zip').write_bytes(b'wrong')
        with self.assertRaisesRegex(p.ReleaseError, 'PUBLICATION_FILE_MISMATCH'): p.validate_site(self.site)

    def test_report_from_other_commit_cannot_be_reused(self):
        self.runner.check()
        report = p.read_json(self.base / 'report.json'); report['commit'] = '0' * 40
        p.atomic_json(self.base / 'report.json', report)
        with self.assertRaisesRegex(p.ReleaseError, 'REPORT_IDENTITY'): p.Runner(self.site, '2.4.3', self.base / 'report.json')

    def test_private_automation_is_not_in_pages_stage(self):
        (self.site / '.release/private-control.txt').write_text('private', encoding='utf-8')
        p.git(self.site, 'add', '.release/private-control.txt')
        self.runner.stage_pages(self.base / 'public')
        self.assertFalse((self.base / 'public/.release').exists())
        self.assertTrue((self.base / 'public/setup-guide.md').exists())

    def test_path_escape_and_invalid_versions_are_rejected(self):
        for name in ('../secret', '/secret', 'a/../../secret', 'C:/secret', 'a\\secret'):
            with self.assertRaises(p.ReleaseError): p.safe_path(self.site, name)
        with self.assertRaises(p.ReleaseError): p.version_number('2.4.3; command')

    def test_github_token_is_not_forwarded_to_artifact_storage(self):
        request = p.Request('https://api.github.com/artifact', headers={'Authorization': 'Bearer fixture-only'})
        redirected = p.SafeRedirect().redirect_request(request, None, 302, 'Found', {}, 'https://storage.example.invalid/file.zip')
        self.assertFalse(redirected.has_header('Authorization'))

    def test_ci_requires_actual_preparation_evidence(self):
        (self.base / 'preparation-verification.json').unlink()
        with patch.dict(p.os.environ, {'GITHUB_ACTIONS': 'true'}):
            with self.assertRaisesRegex(p.ReleaseError, 'PREPARATION_EVIDENCE_REQUIRED'): self.runner.check()

    def test_ci_rejects_evidence_for_a_different_version(self):
        p.atomic_json(self.base / 'preparation-verification.json', {'status': 'passed', 'freshVersion': '2.4.2', 'to': '2.4.2'})
        with patch.dict(p.os.environ, {'GITHUB_ACTIONS': 'true'}):
            with self.assertRaisesRegex(p.ReleaseError, 'PREPARATION_EVIDENCE_MISMATCH'): self.runner.check()

    def test_unfinished_draft_placeholder_can_be_retried(self):
        self.runner.prepare()
        asset = self.api.release['assets'][0]
        asset.update({'id': 100, 'state': 'starter', 'size': 0, 'digest': None})
        self.runner.prepare()
        p.verify_assets(self.api.release, p.expected_assets(self.runner.checked))
        self.assertIn(('/releases/assets/100', 'DELETE'), self.api.mutations)

    def test_only_pinned_historical_text_representation_is_accepted(self):
        folder = self.site / 'releases/course/v1.0.0'; folder.mkdir()
        original = b'historical\r\n'; canonical = b'historical\n'
        (folder / 'CHANGELOG.md').write_bytes(canonical)
        p.atomic_json(folder / 'manifest.json', {'version': '1.0.0', 'files': {'CHANGELOG.md': p.digest(original)}})
        controls = self.base / 'controls'; controls.mkdir()
        p.atomic_json(controls / 'legacy-line-endings.json', {'files': {'releases/course/v1.0.0/CHANGELOG.md': {
            'originalSha256': p.digest(original), 'gitSha256': p.digest(canonical)}}})
        with patch.object(p, '__file__', str(controls / 'pipeline.py')):
            result = p.validate_site(self.site)
            self.assertEqual(len(result['legacyTextRepresentations']), 1)
            (folder / 'CHANGELOG.md').write_bytes(b'changed\n')
            with self.assertRaisesRegex(p.ReleaseError, 'HISTORICAL_FILE_MISMATCH'): p.validate_site(self.site)


if __name__ == '__main__': unittest.main()
