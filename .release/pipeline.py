"""Release gates shared by the local entry and GitHub Actions (stdlib only)."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from hashlib import sha256
from io import BytesIO
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen, build_opener, HTTPRedirectHandler
from zipfile import ZipFile

REPOSITORY = 'siatwangmin/aicoding-course'
PUBLIC = 'https://siatwangmin.github.io/aicoding-course'
API = 'https://api.github.com/repos/' + REPOSITORY


class ReleaseError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def digest(data):
    return sha256(data).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.partial')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def git(site, *args, binary=False):
    result = subprocess.check_output(['git', *args], cwd=site, text=not binary, encoding=None if binary else 'utf-8')
    return result if binary else result.strip()


def safe_path(root, name):
    require(isinstance(name, str) and name and '\\' not in name and ':' not in name and
            not any(ord(c) < 32 for c in name), 'UNSAFE_PATH')
    relative = PurePosixPath(name)
    require(not relative.is_absolute() and all(p not in ('.', '..', '.git') for p in relative.parts), 'UNSAFE_PATH: ' + name)
    target = root / name
    require(target.resolve().is_relative_to(root.resolve()), 'PATH_ESCAPES_ROOT: ' + name)
    require(not any(p.is_symlink() for p in (target, *target.parents) if p != root.parent), 'LINK_NOT_ALLOWED: ' + name)
    return target


def version_number(version):
    require(bool(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)), 'INVALID_VERSION')
    return tuple(map(int, version.split('.')))


def credential(site):
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token:
        return token
    result = subprocess.run(['git', 'credential', 'fill'], cwd=site,
        input='protocol=https\nhost=github.com\n\n', text=True, capture_output=True,
        env={**os.environ, 'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'Never'})
    token = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line).get('password')
    require(result.returncode == 0 and token, 'GITHUB_AUTHENTICATION_REQUIRED')
    return token


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        require(urlparse(new_url).scheme == 'https', 'INSECURE_API_REDIRECT')
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected and urlparse(new_url).hostname != urlparse(request.full_url).hostname:
            redirected.remove_header('Authorization')
        return redirected


class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = build_opener(SafeRedirect())

    def call(self, path, method='GET', data=None, missing=False, binary=False):
        url = path if path.startswith('https://') else API + path
        require(urlparse(url).hostname in ('api.github.com', 'uploads.github.com'), 'UNTRUSTED_API_HOST')
        headers = {'User-Agent': 'verified-environment-release', 'Accept': 'application/vnd.github+json',
                   'Cache-Control': 'no-cache'}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        if isinstance(data, bytes):
            body = data
            headers['Content-Type'] = 'application/octet-stream'
        else:
            body = None if data is None else json.dumps(data, ensure_ascii=False).encode()
            headers['Content-Type'] = 'application/json'
        # Only GET is retried automatically. Mutations are reconciled on resume.
        for attempt in range(3):
            try:
                with self.opener.open(Request(url, data=body, method=method, headers=headers), timeout=45) as response:
                    payload = response.read()
                    return payload if binary else (json.loads(payload) if payload else None)
            except HTTPError as error:
                if error.code == 404 and missing:
                    return None
                if method == 'GET' and error.code in (429, 500, 502, 503, 504) and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise ReleaseError(f'GITHUB_{method}_HTTP_{error.code}') from None
            except (URLError, TimeoutError, OSError):
                if method == 'GET' and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise ReleaseError('GITHUB_NETWORK_INTERRUPTED: resume the same run; do not replace assets') from None


def validate_archive(path, profile, manifest):
    with ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'DUPLICATE_ARCHIVE_PATH')
        for name in names:
            safe_path(Path('/archive'), name)
        bundle_bytes = archive.read('bundle-manifest.json')
        require(digest(bundle_bytes) == profile['bundleManifestSha256'], 'BUNDLE_DIGEST_MISMATCH')
        bundle = json.loads(bundle_bytes)
        require(bundle == profile['bundle'], 'BUNDLE_IDENTITY_MISMATCH')
        require(json.loads(archive.read('VERSION.json'))['version'] == manifest['version'], 'ARCHIVE_VERSION_MISMATCH')
        for name, expected in bundle['files'].items():
            require(digest(archive.read(name)) == expected, 'BUNDLE_FILE_MISMATCH: ' + name)
        for name, skill in bundle['skills'].items():
            payload = archive.read(skill['archive'])
            require(digest(payload) == skill['sha256'], 'SKILL_DIGEST_MISMATCH: ' + name)
            with ZipFile(BytesIO(payload)) as nested:
                members = nested.namelist()
                require(len(members) == len(set(members)), 'DUPLICATE_SKILL_PATH')
                for member in members:
                    safe_path(Path('/archive'), member)
                require({n: digest(nested.read(n)) for n in members} == skill['files'], 'SKILL_FILES_MISMATCH: ' + name)
            require(set(skill.get('requires', [])).issubset(bundle['skills']), 'SKILL_DEPENDENCY_MISSING')
    return bundle


def validate_site(site, version=None):
    site = Path(site).resolve()
    info = read_json(site / 'VERSION.json')
    version = version or info['version']
    version_number(version)
    require(info['version'] == version and info['gitTag'] == 'course-v' + version, 'VERSION_IDENTITY_MISMATCH')
    publication = read_json(site / 'publication.json')
    require(publication['version'] == version and publication['status'] == 'release', 'PUBLICATION_IDENTITY_MISMATCH')
    for name, expected in publication['files'].items():
        require(re.fullmatch('[a-f0-9]{64}', expected) is not None, 'INVALID_DIGEST')
        path = safe_path(site, name)
        require(path.is_file() and digest(path.read_bytes()) == expected, 'PUBLICATION_FILE_MISMATCH: ' + name)
    fixed = site / 'releases/course' / ('v' + version)
    manifest_bytes = (fixed / 'release-manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    index = read_json(site / 'release-index.json')
    entry = index['versions'][version]
    base = PUBLIC + '/releases/course/v' + version
    require(index['latest'] == version and entry['status'] == 'release', 'INDEX_VERSION_MISMATCH')
    require(entry['manifestSha256'] == digest(manifest_bytes) and entry['baseUrl'] == base and
            entry['manifestUrl'] == base + '/release-manifest.json', 'INDEX_POINTER_MISMATCH')
    require(manifest['version'] == version and manifest['status'] == 'release' and manifest['baseUrl'] == base, 'FIXED_MANIFEST_MISMATCH')
    # All retained frozen snapshots must still satisfy their own original manifests.
    snapshots = list((site / 'releases/course').glob('v*/manifest.json'))
    legacy_file = Path(__file__).parent / 'legacy-line-endings.json'
    legacy = read_json(legacy_file)['files'] if legacy_file.exists() else {}
    legacy_matches = []
    for snapshot in snapshots:
        data = read_json(snapshot)
        for name, expected in data['files'].items():
            path = safe_path(snapshot.parent, name)
            actual = digest(path.read_bytes())
            if actual != expected:
                relative = path.relative_to(site).as_posix()
                known = legacy.get(relative, {})
                require(known.get('originalSha256') == expected and known.get('gitSha256') == actual,
                        'HISTORICAL_FILE_MISMATCH: ' + relative)
                legacy_matches.append(relative)
        website = snapshot.parent / 'website-manifest.json'
        if website.exists():
            for name, expected in read_json(website)['files'].items():
                require(digest(safe_path(snapshot.parent / 'website', name).read_bytes()) == expected, 'HISTORICAL_WEBSITE_MISMATCH: ' + name)
    for name, expected in manifest['files'].items():
        require(digest(safe_path(fixed, name).read_bytes()) == expected, 'FIXED_FILE_MISMATCH: ' + name)
    profiles = {}
    require('generic' in manifest['profiles'], 'GENERIC_PACKAGE_REQUIRED')
    for name, profile in manifest['profiles'].items():
        archive = safe_path(fixed, profile['archive'])
        require(digest(archive.read_bytes()) == profile['sha256'], 'PACKAGE_DIGEST_MISMATCH: ' + name)
        profiles[name] = validate_archive(archive, profile, manifest)
    archives = list(fixed.glob('*.zip'))
    require({p.with_suffix('.sha256') for p in archives} == set(fixed.glob('*.sha256')), 'CHECKSUM_SET_MISMATCH')
    for archive in archives:
        require(archive.with_suffix('.sha256').read_text(encoding='utf-8').split() == [digest(archive.read_bytes()), archive.name], 'CHECKSUM_MISMATCH: ' + archive.name)
    guide = (site / 'setup-guide.md').read_text(encoding='utf-8')
    for marker in ('Get-CourseMaterials.ps1', 'Update-CourseMaterials.ps1', 'release-index.json', 'CourseVersion', '-Action Check', '-Action Apply'):
        require(marker in guide, 'STABLE_ENTRY_MISSING: ' + marker)
    require(not re.search('本课程|课前|课堂|学习|教学|学员资料包', guide), 'STABLE_ENTRY_WORDING')
    request = site / '.release/request.json'
    if request.exists():
        data = read_json(request)
        require(data['version'] == version and data['publicationSha256'] == digest((site / 'publication.json').read_bytes()), 'RELEASE_REQUEST_MISMATCH')
    return {'version': version, 'tag': info['gitTag'], 'manifest': manifest, 'profiles': profiles,
            'publication': publication, 'fixed': fixed, 'snapshots': len(snapshots), 'legacyTextRepresentations': legacy_matches}


def expected_assets(checked):
    folder = checked['fixed']
    files = sorted([*folder.glob('*.zip'), *folder.glob('*.sha256'), folder / 'VERSION.json', folder / 'release-manifest.json'])
    return {p.name: {'digest': 'sha256:' + digest(p.read_bytes()), 'size': p.stat().st_size, 'path': p} for p in files}


def verify_assets(release, expected):
    actual = {a['name']: a for a in release['assets']}
    require(len(actual) == len(release['assets']) and set(actual) == set(expected), 'RELEASE_ATTACHMENT_SET_MISMATCH')
    for name, wanted in expected.items():
        require(actual[name].get('digest') == wanted['digest'] and actual[name]['size'] == wanted['size'], 'RELEASE_ATTACHMENT_MISMATCH: ' + name)


class Runner:
    def __init__(self, site, version, report, github=None, expected_commit=None):
        self.site = Path(site).resolve()
        self.checked = validate_site(self.site, version)
        self.version = self.checked['version']
        self.tag = self.checked['tag']
        self.commit = git(self.site, 'rev-parse', 'HEAD')
        require(not expected_commit or expected_commit == self.commit, 'CHECKOUT_COMMIT_MISMATCH')
        self.github = github
        self.report_path = Path(report)
        self.report = read_json(report) if Path(report).exists() else {
            'schemaVersion': 1, 'version': self.version, 'commit': self.commit,
            'runId': os.environ.get('GITHUB_RUN_ID'), 'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
            'workflowUrl': os.environ.get('GITHUB_SERVER_URL', 'https://github.com') + '/' + REPOSITORY + '/actions/runs/' + os.environ.get('GITHUB_RUN_ID', ''),
            'publicationSha256': digest((self.site / 'publication.json').read_bytes()), 'checks': {}}
        request_file = self.site / '.release/request.json'
        if request_file.exists():
            self.report['source'] = read_json(request_file).get('source')
        require(self.report['version'] == self.version and self.report['commit'] == self.commit and
                self.report['publicationSha256'] == digest((self.site / 'publication.json').read_bytes()), 'REPORT_IDENTITY_MISMATCH')

    def save(self, **fields):
        self.report.update(fields)
        self.report['updatedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        atomic_json(self.report_path, self.report)

    def current_head(self):
        require(self.github.call('/commits/main')['sha'] == self.commit, 'STALE_RELEASE_COMMIT: current main has changed')

    def check(self):
        preparation = self.report_path.parent / 'preparation-verification.json'
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            require(preparation.exists(), 'PREPARATION_EVIDENCE_REQUIRED')
            evidence = read_json(preparation)
            require(evidence['status'] == 'passed' and evidence['freshVersion'] == self.version and evidence['to'] == self.version,
                    'PREPARATION_EVIDENCE_MISMATCH')
            self.report['checks']['preparation'] = {'status': 'passed', 'from': evidence['from'], 'to': evidence['to']}
        self.report['checks']['local'] = {'status': 'passed', 'files': len(self.checked['publication']['files']),
            'historicalSnapshots': self.checked['snapshots'], 'legacyTextRepresentations': self.checked['legacyTextRepresentations']}
        self.save(status='running')

    def find_release(self):
        release = self.github.call('/releases/tags/' + self.tag, missing=True)
        if release:
            return release
        # Draft releases may not be returned by the tag endpoint. Reconcile before POST.
        for page in range(1, 21):
            releases = self.github.call('/releases?per_page=100&page=' + str(page))
            match = next((r for r in releases if r['tag_name'] == self.tag), None)
            if match:
                return match
            if len(releases) < 100:
                return None
        raise ReleaseError('RELEASE_LIST_LIMIT')

    def prepare(self):
        self.current_head()
        ref = self.github.call('/git/ref/tags/' + self.tag, missing=True)
        if ref:
            tagged = ref['object']['sha']
            while ref['object']['type'] == 'tag':
                ref = self.github.call('/git/tags/' + tagged)
                tagged = ref['object']['sha']
            # Stable-entry repairs may advance main; compare the fixed package at the original tag.
            for name in ('manifest.json', 'release-manifest.json'):
                path = 'releases/course/v' + self.version + '/' + name
                original = git(self.site, 'show', tagged + ':' + path, binary=True)
                require(original == (self.site / path).read_bytes(), 'EXISTING_TAG_CONTENT_CHANGED')
        else:
            latest = self.github.call('/releases/latest', missing=True)
            if latest:
                require(version_number(self.version) > version_number(latest['tag_name'].removeprefix('course-v')), 'VERSION_MUST_ADVANCE')
            self.github.call('/git/refs', 'POST', {'ref': 'refs/tags/' + self.tag, 'sha': self.commit})
            tagged = self.commit
        release = self.find_release()
        if not release:
            request = read_json(self.site / '.release/request.json')
            release = self.github.call('/releases', 'POST', {'tag_name': self.tag, 'target_commitish': tagged,
                'name': 'AI Coding v' + self.version, 'body': request['notes'], 'draft': True, 'prerelease': False})
        require(not release['prerelease'], 'EXISTING_PRERELEASE_CONFLICT')
        expected = expected_assets(self.checked)
        assets = {a['name']: a for a in release['assets']}
        require(set(assets).issubset(expected), 'UNEXPECTED_RELEASE_ASSET')
        for name, wanted in expected.items():
            asset = assets.get(name)
            # GitHub can retain a zero-byte starter after a broken draft upload.
            # Only that unfinished placeholder is disposable; completed bytes never are.
            if asset and release['draft'] and asset.get('state') == 'starter' and asset.get('size') == 0 and not asset.get('digest'):
                pending = self.github.call('/releases/assets/' + str(asset['id']))
                if pending.get('state') == 'starter' and pending.get('size') == 0 and not pending.get('digest'):
                    self.github.call('/releases/assets/' + str(asset['id']), 'DELETE')
                    asset = None
                else:
                    asset = pending
            if not asset:
                require(release['draft'], 'PUBLISHED_RELEASE_MISSING_ASSET: refuse to alter a published release')
                asset = self.github.call(release['upload_url'].split('{')[0] + '?name=' + quote(name), 'POST', wanted['path'].read_bytes())
            require(asset.get('digest') == wanted['digest'] and asset['size'] == wanted['size'], 'ASSET_MISMATCH_PRESERVED: ' + name)
        final = self.github.call('/releases/' + str(release['id']))
        verify_assets(final, expected)
        self.report['checks']['attachments'] = {'status': 'passed', 'count': len(expected)}
        self.save(status='running', tagCommit=tagged, releaseId=release['id'], releaseUrl=release['html_url'])

    def stage_pages(self, destination):
        destination = Path(destination).resolve()
        require(not destination.is_relative_to(self.site) and not self.site.is_relative_to(destination), 'PAGES_STAGE_MUST_BE_SEPARATE')
        require(not destination.exists() or not any(destination.iterdir()), 'PAGES_STAGE_NOT_EMPTY')
        destination.mkdir(parents=True, exist_ok=True)
        names = git(self.site, 'ls-files', '-z').split('\0')
        for name in names:
            if not name or PurePosixPath(name).parts[0] in ('.github', '.release', 'AGENTS.md'):
                continue
            source = safe_path(self.site, name)
            target = safe_path(destination, name)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        self.save(status='running', pagesStage=str(destination))

    def verify_pages(self, fetch=None, attempts=8):
        wanted = self.checked['publication']['files']
        paths = ['publication.json', 'VERSION.json', 'release-index.json', 'setup-guide.md', 'Get-CourseMaterials.ps1',
                 'Update-CourseMaterials.ps1', 'index.html', 'preparation.html', 'course/index.html',
                 'course/preparation.html', 'course/course-steps.json', 'ai-coding-toolkit.zip',
                 'releases/course/v' + self.version + '/VERSION.json',
                 'releases/course/v' + self.version + '/release-manifest.json',
                 'releases/course/v' + self.version + '/ai-coding-toolkit.zip']
        expected = {p: wanted.get(p) or digest((self.site / p).read_bytes()) for p in paths}
        def download(url):
            with urlopen(Request(url, headers={'User-Agent': 'release-public-verification', 'Cache-Control': 'no-cache'}), timeout=30) as response:
                return response.read()
        fetch = fetch or download
        pending = set(paths)
        verified = {}
        for attempt in range(attempts):
            def one(path):
                payload = fetch(PUBLIC + '/' + quote(path, safe='/') + '?release-check=' + self.commit)
                require(digest(payload) == expected[path], 'PUBLIC_FILE_MISMATCH: ' + path)
                if path.endswith('.zip'):
                    with ZipFile(BytesIO(payload)) as z:
                        require(json.loads(z.read('VERSION.json'))['version'] == self.version, 'PUBLIC_PACKAGE_VERSION_MISMATCH')
                return path
            with ThreadPoolExecutor(max_workers=4) as pool:
                for future in as_completed({pool.submit(one, path): path for path in pending}):
                    try:
                        path = future.result()
                        verified[path] = expected[path]
                    except (ReleaseError, HTTPError, URLError, TimeoutError, OSError) as error:
                        print('Waiting for public content:', type(error).__name__, flush=True)
            pending -= verified.keys()
            if not pending:
                self.report['checks']['pages'] = {'status': 'passed', 'files': verified}
                self.save(status='running', pagesUrl=PUBLIC + '/')
                return
            if attempt + 1 < attempts:
                time.sleep(min(10 * (attempt + 1), 30))
        raise ReleaseError('PUBLIC_CONTENT_NOT_READY: ' + ', '.join(sorted(pending)))

    def finalize(self):
        self.current_head()
        for gate in ('local', 'attachments', 'pages'):
            require(self.report.get('checks', {}).get(gate, {}).get('status') == 'passed', 'RELEASE_GATE_MISSING: ' + gate)
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            require(self.report['checks'].get('preparation', {}).get('status') == 'passed', 'PREPARATION_GATE_MISSING')
        latest = self.github.call('/releases/latest', missing=True)
        if latest:
            require(version_number(latest['tag_name'].removeprefix('course-v')) <= version_number(self.version), 'REFUSE_LATEST_DOWNGRADE')
        release = self.find_release()
        require(release is not None, 'RELEASE_NOT_PREPARED')
        verify_assets(release, expected_assets(self.checked))
        self.github.call('/releases/' + str(release['id']), 'PATCH', {'draft': False, 'prerelease': False, 'make_latest': 'true'})
        public = GitHub('')
        # Public metadata must agree too; an authenticated draft response is not publication evidence.
        for attempt in range(6):
            final = public.call('/releases/tags/' + self.tag, missing=True)
            latest = public.call('/releases/latest', missing=True)
            if final and latest and not final['draft'] and not final['prerelease'] and latest['tag_name'] == self.tag:
                break
            if attempt < 5: time.sleep(5)
        require(final and latest and not final['draft'] and not final['prerelease'] and latest['tag_name'] == self.tag, 'PUBLIC_RELEASE_NOT_CURRENT')
        verify_assets(final, expected_assets(self.checked))
        self.report['checks']['release'] = {'status': 'passed', 'latest': latest['tag_name'], 'assets': len(final['assets'])}
        self.save(status='success', completedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['check', 'prepare', 'stage-pages', 'verify-pages', 'finalize'])
    parser.add_argument('--site', type=Path, default=Path.cwd())
    parser.add_argument('--version', default=os.environ.get('EXPECTED_VERSION') or None)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--destination', type=Path)
    args = parser.parse_args()
    runner = None
    try:
        runner = Runner(args.site, args.version, args.report, expected_commit=os.environ.get('GITHUB_SHA'))
        if args.phase in ('prepare', 'finalize'):
            runner.github = GitHub(credential(args.site))
        if args.phase == 'check': runner.check()
        elif args.phase == 'prepare': runner.prepare()
        elif args.phase == 'stage-pages': runner.stage_pages(args.destination)
        elif args.phase == 'verify-pages': runner.verify_pages()
        elif args.phase == 'finalize': runner.finalize()
        print('PASS:', args.phase, runner.version, flush=True)
    except Exception as error:
        message = str(error) if isinstance(error, ReleaseError) else type(error).__name__
        if runner:
            runner.save(status='failed', failedPhase=args.phase, error=message)
        else:
            atomic_json(args.report, {'status': 'failed', 'failedPhase': args.phase, 'error': message, 'version': args.version,
                                      'commit': os.environ.get('GITHUB_SHA'), 'checks': {}})
        print('FAILED:', message, flush=True)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
