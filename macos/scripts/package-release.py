#!/usr/bin/env python3
"""构建 TaoScreen 发布产物。正式发布支持签名、公证、Sparkle 与 R2，GitHub Release 可按 tag 单独打包通用 DMG。"""
import argparse
import base64
import hashlib
import fcntl
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

SIGN_IDENTITY = os.environ.get('TAOSCREEN_SIGN_IDENTITY', '')
NOTARY_PROFILE = os.environ.get('TAOSCREEN_NOTARY_PROFILE', '')
R2_ACCOUNT_ID = os.environ.get('TAOSCREEN_R2_ACCOUNT_ID', '')
R2_BUCKET = os.environ.get('TAOSCREEN_R2_BUCKET', '')
RELEASE_ORIGIN = os.environ.get('TAOSCREEN_RELEASE_ORIGIN', '').rstrip('/')
UPDATE_SERVER = os.environ.get('TAOSCREEN_UPDATE_SERVER', '').rstrip('/')
UPDATE_KEY_ACCOUNT = os.environ.get('TAOSCREEN_UPDATE_KEY_ACCOUNT', '')
BUNDLE_ID = os.environ.get('TAOSCREEN_BUNDLE_ID', '')
TEAM_ID = os.environ.get('TAOSCREEN_TEAM_ID', '')
DISPLAY_NAME = 'TaoScreen'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE_NS)

VERSION_PATTERN = re.compile(r'(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})')

root = pathlib.Path(__file__).resolve().parents[1]
output = root / 'dist/releases'


def update_key_path():
    path = os.environ.get('TAOSCREEN_UPDATE_PUBLIC_KEY_FILE')
    return pathlib.Path(path).expanduser() if path else root / '.release/update-public.plist'


def publisher_requirement(bundle_id=None):
    identifier = f'identifier "{bundle_id}" and ' if bundle_id else ''
    return (f'={identifier}anchor apple generic'
            ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
            ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
            f' and certificate leaf[subject.OU] = "{TEAM_ID}"')


def check_config(args):
    required = {'TAOSCREEN_UPDATE_KEY_ACCOUNT': UPDATE_KEY_ACCOUNT}
    if not args.init_update_key:
        required.update(TAOSCREEN_RELEASE_ORIGIN=RELEASE_ORIGIN, TAOSCREEN_TEAM_ID=TEAM_ID)
        if not args.upload_only:
            required.update(TAOSCREEN_SIGN_IDENTITY=SIGN_IDENTITY, TAOSCREEN_NOTARY_PROFILE=NOTARY_PROFILE,
                            TAOSCREEN_BUNDLE_ID=BUNDLE_ID)
        if args.upload or args.upload_only:
            required.update(TAOSCREEN_R2_ACCOUNT_ID=R2_ACCOUNT_ID, TAOSCREEN_R2_BUCKET=R2_BUCKET,
                            TAOSCREEN_UPDATE_SERVER=UPDATE_SERVER)
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise SystemExit('请先配置发布环境变量：' + '、'.join(missing))
    if args.init_update_key:
        return
    if not re.fullmatch(r'[A-Z0-9]{10}', TEAM_ID):
        raise SystemExit('TAOSCREEN_TEAM_ID 必须是 10 位 Apple Team ID')
    if not args.upload_only and not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', BUNDLE_ID):
        raise SystemExit('TAOSCREEN_BUNDLE_ID 必须是有效的 Bundle ID')
    for url in filter(None, (RELEASE_ORIGIN, UPDATE_SERVER)):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None or parsed.path or parsed.query or parsed.fragment:
            raise SystemExit('发布源和服务器地址必须使用 HTTPS 根地址')


def notarize(submission, target):
    command = ['xcrun', 'notarytool', 'submit', str(submission), '--keychain-profile', NOTARY_PROFILE, '--wait']
    if keychain := os.environ.get('TAOSCREEN_NOTARY_KEYCHAIN'):
        command.extend(['--keychain', keychain])
    subprocess.run(command, check=True)
    subprocess.run(['xcrun', 'stapler', 'staple', str(target)], check=True)


def version_parts(version):
    return tuple(map(int, version.split('.')))


def package_name(version, arch, extension='dmg'):
    return f'{DISPLAY_NAME}-{version}-{arch}.{extension}'


def sparkle_tool(name):
    for artifacts in (root / '.build/artifacts', root / '.build/SourcePackages/artifacts'):
        tool = artifacts / 'sparkle/Sparkle/bin' / name
        if tool.is_file():
            return str(tool)
    raise SystemExit('未找到 Sparkle 发布工具，请先运行 swift package resolve')


def public_key():
    return subprocess.check_output([sparkle_tool('generate_keys'), '--account', UPDATE_KEY_ACCOUNT, '-p'], text=True).strip()


def release_info(plist_path):
    info = plistlib.loads(plist_path.read_bytes())
    key_path = update_key_path()
    info['SUPublicEDKey'] = plistlib.loads(key_path.read_bytes()).get('SUPublicEDKey', '') if key_path.exists() else ''
    return info


def check_update_key(info):
    key = info.get('SUPublicEDKey', '')
    try:
        valid = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid = False
    if not valid:
        raise SystemExit('缺少有效的 TaoScreen 更新公钥，请先运行 python3 scripts/package-release.py --init-update-key')
    if public_key() != key:
        raise SystemExit('TaoScreen 更新公钥与本机独立钥匙串密钥不匹配，已停止发布')


def init_update_key(plist_path):
    info = plistlib.loads(plist_path.read_bytes()) if plist_path.exists() else {}
    if info.get('SUPublicEDKey'):
        check_update_key(info)
        print('TaoScreen 更新密钥已配置，不做变更。')
        return
    subprocess.run([sparkle_tool('generate_keys'), '--account', UPDATE_KEY_ACCOUNT], check=True, stdout=subprocess.DEVNULL)
    info['SUPublicEDKey'] = public_key()
    plist_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print('已配置 TaoScreen 独立更新公钥，私钥仅保存在本机钥匙串中。')


def build_number(version):
    major, minor, patch = version_parts(version)
    return str(major * 100000000 + minor * 10000 + patch)


def appcast_data(version, arch, notes, size, signature):
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = f'{DISPLAY_NAME} 更新'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'{DISPLAY_NAME} {version}'
    ET.SubElement(item, 'description', {f'{{{SPARKLE_NS}}}format': 'plain-text'}).text = notes
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    for name, value in (('version', build_number(version)), ('shortVersionString', version),
                        ('minimumSystemVersion', '14.0'), ('hardwareRequirements', arch)):
        ET.SubElement(item, f'{{{SPARKLE_NS}}}{name}').text = value
    ET.SubElement(item, 'enclosure', {
        'url': f'{RELEASE_ORIGIN}/macos/{version}/{package_name(version, arch, "zip")}',
        'length': str(size), 'type': 'application/octet-stream', f'{{{SPARKLE_NS}}}edSignature': signature})
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n'


def verify_appcast(data, version, arch, archive, info):
    """上传前绑定版本、架构、地址、包大小和签名，避免把另一份清单发布到当前渠道。"""
    channel = ET.fromstring(data).find('channel')
    items = channel.findall('item') if channel is not None else []
    if len(items) != 1:
        raise SystemExit('Sparkle 清单必须包含本次唯一版本')
    item = items[0]
    expected = {'version': build_number(version), 'shortVersionString': version,
                'minimumSystemVersion': info['LSMinimumSystemVersion'], 'hardwareRequirements': arch}
    if any(item.findtext(f'{{{SPARKLE_NS}}}{key}') != value for key, value in expected.items()):
        raise SystemExit('Sparkle 清单的版本、系统要求或架构不匹配')
    enclosure = item.find('enclosure')
    url = f'{RELEASE_ORIGIN}/macos/{version}/{package_name(version, arch, "zip")}'
    if enclosure is None or enclosure.get('url') != url or enclosure.get('length') != str(archive.stat().st_size):
        raise SystemExit('Sparkle 清单的下载地址或大小不匹配')
    signature = enclosure.get(f'{{{SPARKLE_NS}}}edSignature', '')
    try:
        valid = len(base64.b64decode(signature, validate=True)) == 64
    except ValueError:
        valid = False
    if not valid:
        raise SystemExit('Sparkle 更新签名无效')
    check_update_key(info)
    subprocess.run([sparkle_tool('sign_update'), '--account', UPDATE_KEY_ACCOUNT,
                    '--verify', str(archive), signature], check=True)


def published_versions(arch):
    versions = []
    manifest = fetch(f'{RELEASE_ORIGIN}/taoscreen-macos-{arch}.json', probe=True)
    if manifest is not None:
        versions.append(json.loads(manifest)['version'])
    feed = fetch(f'{RELEASE_ORIGIN}/taoscreen-appcast-{arch}.xml', probe=True)
    if feed is not None:
        versions.extend(item.findtext(f'{{{SPARKLE_NS}}}shortVersionString', '') for item in ET.fromstring(feed).findall('channel/item'))
    if any(not VERSION_PATTERN.fullmatch(version) for version in versions):
        raise SystemExit('线上清单版本无效，已停止发布')
    return versions


def resolve_version(requested, upload_only, arch, plist_path):
    """未指定版本时，上传沿用本地清单；新构建沿用工程版本，该版本已生成或已发布时递增修订号。"""
    if requested:
        return requested
    if upload_only:
        manifest_path = output / f'taoscreen-macos-{arch}.json'
        if not manifest_path.exists():
            raise SystemExit('没有本地发布文件，无法确定要上传的版本')
        return json.loads(manifest_path.read_text())['version']
    version = plistlib.loads(plist_path.read_bytes())['CFBundleShortVersionString']
    versions = published_versions(arch)
    if versions:
        latest = max(versions, key=version_parts)
        if version_parts(latest) >= version_parts(version):
            version = next_version(latest)
    while any((output / 'macos' / version / package_name(version, arch, ext)).exists() or fetch(f'{RELEASE_ORIGIN}/macos/{version}/{package_name(version, arch, ext)}', probe=True) is not None for ext in ('dmg', 'zip')):
        version = next_version(version)
    return version


def next_version(version):
    major, minor, patch = version_parts(version)
    if patch >= 9999:
        raise SystemExit('修订号已达 9999，请显式指定新的次版本或主版本')
    return f'{major}.{minor}.{patch + 1}'


def wrangler(*arguments, **options):
    return subprocess.run(['wrangler', *arguments], env={**os.environ, 'CLOUDFLARE_ACCOUNT_ID': R2_ACCOUNT_ID}, **options)


def fetch(url, probe=False):
    """返回响应内容，对象不存在时返回 None。probe 附带一次性查询参数，避免上传前的 404 留在边缘缓存。"""
    request = urllib.request.Request(f'{url}?probe={uuid.uuid4().hex}' if probe else url,
                                     headers={'Cache-Control': 'no-cache', 'User-Agent': 'TaoScreen-Release'})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def wait_until(check, failure, attempts=12, delay=10):
    for attempt in range(attempts):
        try:
            if check():
                return
        except OSError as error:
            print(f'校验请求失败：{error}')
        if attempt + 1 < attempts:
            time.sleep(delay)
    raise SystemExit(failure)


def check_upload_ready(version, arch, fresh):
    """构建和公证之前确认能写入 TaoScreen 的发布桶，且本次发布不会覆盖或回退线上版本。"""
    if shutil.which('wrangler') is None:
        raise SystemExit('未找到 wrangler，无法上传 R2')
    access = wrangler('r2', 'bucket', 'info', R2_BUCKET, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if access.returncode != 0:
        raise SystemExit(f'{access.stderr.strip()}\n\n无法访问 R2 桶 {R2_BUCKET}（账户 {R2_ACCOUNT_ID}），请确认已运行 wrangler login，且账号能访问该账户')
    versions = published_versions(arch)
    if versions and version_parts(max(versions, key=version_parts)) > version_parts(version):
        raise SystemExit('线上已有更高版本，禁止回退任一更新渠道')
    if fresh and any(fetch(f'{RELEASE_ORIGIN}/macos/{version}/{package_name(version, arch, ext)}', probe=True) is not None for ext in ('dmg', 'zip')):
        raise SystemExit('线上已有同版本安装包，禁止覆盖，请增加版本号')


def upload_artifact(package, content_type):
    url = f'{RELEASE_ORIGIN}/macos/{package.parent.name}/{package.name}'
    data = package.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    published = fetch(url, probe=True)
    if published is None:
        wrangler('r2', 'object', 'put', f'{R2_BUCKET}/macos/{package.parent.name}/{package.name}',
                 '--remote', '--file', str(package), '--content-type', content_type, check=True)
    elif hashlib.sha256(published).hexdigest() != digest:
        raise SystemExit('线上已有同版本但内容不同的安装包，禁止覆盖，请增加版本号')
    else:
        print(f'线上已有相同安装包，跳过上传：{package.name}')

    def available():
        downloaded = fetch(url)
        return downloaded is not None and len(downloaded) == len(data) and hashlib.sha256(downloaded).hexdigest() == digest
    wait_until(available, f'公开下载校验失败：{package.name}，更新清单尚未切换')


def upload(version, arch):
    """先验证两套本地产物，再上传不可变包，公开校验成功后发布本次清单。"""
    manifest_path = output / f'taoscreen-macos-{arch}.json'
    feed_path = output / f'taoscreen-appcast-{arch}.xml'
    package = output / 'macos' / version / package_name(version, arch)
    archive = package.with_suffix('.zip')
    if not all(path.is_file() for path in (manifest_path, feed_path, package, archive)):
        raise SystemExit(f'缺少 {version} 的 DMG、ZIP 或清单，请先生成完整发布文件')
    manifest = json.loads(manifest_path.read_text())
    package_data = package.read_bytes()
    if manifest['version'] != version or manifest['size'] != len(package_data) or manifest['sha256'] != hashlib.sha256(package_data).hexdigest():
        raise SystemExit('本地清单与安装包不一致，已停止上传')
    expected_url = f'{RELEASE_ORIGIN}/macos/{version}/{package_name(version, arch)}'
    if manifest.get('platform') != 'macos' or manifest.get('arch') != arch or manifest.get('url') != expected_url:
        raise SystemExit('本地清单的架构或下载地址无效，已停止上传')
    feed = feed_path.read_bytes()
    info = release_info(root / 'Resources/Info.plist')
    verify_appcast(feed, version, arch, archive, info)
    if ET.fromstring(feed).findtext('channel/item/description') != manifest['notes']:
        raise SystemExit('ZIP 与 DMG 清单的更新说明不一致，已停止上传')
    subprocess.run(['codesign', '--verify', '--strict', '-R', publisher_requirement(), str(package)], check=True)
    subprocess.run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', str(package)], check=True)
    # 任一包冲突时，在上传另一包或切换清单之前停止。
    for artifact in (archive, package):
        existing = fetch(f'{RELEASE_ORIGIN}/macos/{version}/{artifact.name}', probe=True)
        if existing is not None and hashlib.sha256(existing).digest() != hashlib.sha256(artifact.read_bytes()).digest():
            raise SystemExit('线上已有同版本但内容不同的安装包，禁止覆盖，请增加版本号')
    upload_artifact(archive, 'application/zip')
    upload_artifact(package, 'application/x-apple-diskimage')
    for path, content_type in ((feed_path, 'application/xml'), (manifest_path, 'application/json')):
        wrangler('r2', 'object', 'put', f'{R2_BUCKET}/{path.name}', '--remote', '--file', str(path),
                 '--content-type', content_type, '--cache-control', 'no-cache', check=True)
        wait_until(lambda: fetch(f'{RELEASE_ORIGIN}/{path.name}') == path.read_bytes(), f'{path.name} 已上传但公开访问未同步，请重试 --upload-only')

    def server_updated():
        data = fetch(f'{UPDATE_SERVER}/v1/desktop/updates/latest?platform=macos&arch={arch}&current={version}')
        release = json.loads(data)['release'] if data is not None else {}
        return release.get('version') == version and release.get('sha256') == manifest['sha256']
    wait_until(server_updated, '清单已上传，但下载接口未返回新版本，请检查线上状态')
    print(f'已发布 {version}（{arch}），Sparkle 与下载接口均已返回新版本。')


def create_disk_image(app, disk_image, version):
    staging = disk_image.parent / 'staging'
    staging.mkdir()
    shutil.copytree(app, staging / 'TaoScreen.app', symlinks=True)
    (staging / 'Applications').symlink_to('/Applications')
    subprocess.run(['hdiutil', 'create', '-volname', f'{DISPLAY_NAME} {version}', '-srcfolder', str(staging),
                    '-format', 'UDZO', str(disk_image)], check=True)


def notarize_app(app, archive):
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
    notarize(archive, app)
    subprocess.run(['spctl', '--assess', '--type', 'execute', '-vv', str(app)], check=True)


def notarize_disk_image(disk_image):
    subprocess.run(['codesign', '--force', '--sign', SIGN_IDENTITY, '--timestamp', str(disk_image)], check=True)
    notarize(disk_image, disk_image)
    subprocess.run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '-vv', str(disk_image)], check=True)


def github_version(tag):
    version = tag.removeprefix('v')
    if not tag.startswith('v') or not VERSION_PATTERN.fullmatch(version):
        raise SystemExit('GitHub 发布 tag 必须为 vX.Y.Z，每段为不带前导零的 0–9999')
    return version


def verify_github_app(app, version):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != build_number(version):
        raise SystemExit('构建应用的版本与 GitHub tag 不一致，已停止打包')
    architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/TaoScreen')], text=True)
    if set(architectures.split()) != {'arm64', 'x86_64'}:
        raise SystemExit('构建应用缺少 Apple Silicon 或 Intel 架构，已停止打包')


def build_github_dmg(tag):
    version = github_version(tag)
    app = root / 'dist/TaoScreen.app'
    package = app.parent / package_name(version, 'universal')
    with tempfile.TemporaryDirectory(prefix='taoscreen-github-release-') as work:
        work = pathlib.Path(work)
        plist_path = work / 'Info.plist'
        info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
        info['CFBundleShortVersionString'] = version
        info['CFBundleVersion'] = build_number(version)
        plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))

        subprocess.run(['bash', str(root / 'scripts/build-app.sh'), 'Release'], check=True, env={
            **os.environ,
            'TAOSCREEN_BUILD_UNIVERSAL': '1',
            'TAOSCREEN_BUILD_INFO_PLIST': str(plist_path),
            'TAOSCREEN_SIGN_IDENTITY': '',
            'TAOSCREEN_APP_ENTITLEMENTS': '',
            'TAOSCREEN_PROVISIONING_PROFILE': '',
            'TAOSCREEN_BUNDLE_ID': '',
            'TAOSCREEN_OAUTH_CALLBACK_SCHEME': '',
            'TAOSCREEN_DEFAULT_SERVER_URL': '',
            'TAOSCREEN_UPDATE_FEED_URL': '',
            'TAOSCREEN_UPDATE_PUBLIC_KEY': '',
        })
        verify_github_app(app, version)
        disk_image = work / package.name
        create_disk_image(app, disk_image, version)
        shutil.move(disk_image, package)
    print(f'已生成：{package}')


def sign_github_dmg(tag, app):
    version = github_version(tag)
    if not SIGN_IDENTITY or not NOTARY_PROFILE or not re.fullmatch(r'[A-Z0-9]{10}', TEAM_ID):
        raise SystemExit('GitHub 公证需要配置签名身份、Apple Team ID 和公证配置')
    app = pathlib.Path(app).resolve()
    verify_github_app(app, version)
    package = root / 'dist' / package_name(version, 'universal')
    with tempfile.TemporaryDirectory(prefix='taoscreen-github-signing-') as temporary:
        work = pathlib.Path(temporary)
        signed_app = work / 'TaoScreen.app'
        subprocess.run(['ditto', str(app), str(signed_app)], check=True)
        subprocess.run(['bash', str(root / 'scripts/sign-app.sh'), str(signed_app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', publisher_requirement(), str(signed_app)], check=True)
        notarize_app(signed_app, work / 'TaoScreen.zip')
        disk_image = work / package.name
        create_disk_image(signed_app, disk_image, version)
        notarize_disk_image(disk_image)
        package.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(disk_image, package)
    print(f'已生成公证安装包：{package}')


def build(version, notes, arch, plist_path):
    plist = plistlib.loads(plist_path.read_bytes())
    plist['CFBundleShortVersionString'] = version
    plist['CFBundleVersion'] = build_number(version)
    plist_path.write_bytes(plistlib.dumps(plist, sort_keys=False))
    info = release_info(plist_path)
    info['SUFeedURL'] = f'{RELEASE_ORIGIN}/taoscreen-appcast-{arch}.xml'
    info['TaoScreenDefaultServerURL'] = UPDATE_SERVER
    subprocess.run(['bash', str(root / 'scripts/build-app.sh'), 'Release'], check=True,
                   env={**os.environ, 'TAOSCREEN_SIGN_IDENTITY': SIGN_IDENTITY, 'TAOSCREEN_BUNDLE_ID': BUNDLE_ID,
                        'TAOSCREEN_DEFAULT_SERVER_URL': UPDATE_SERVER,
                        'TAOSCREEN_UPDATE_FEED_URL': info['SUFeedURL'], 'TAOSCREEN_UPDATE_PUBLIC_KEY': info['SUPublicEDKey']})
    app = root / 'dist/TaoScreen.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R',
                    publisher_requirement(BUNDLE_ID), str(app)], check=True)
    built_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(built_info.get(key) != info[key] for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'SUPublicEDKey', 'SUFeedURL', 'TaoScreenDefaultServerURL')):
        raise SystemExit('构建应用的版本、默认服务器或 Sparkle 配置不匹配，已停止打包')
    package = output / 'macos' / version / package_name(version, arch)
    package.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='taoscreen-release-') as work:
        work = pathlib.Path(work)
        notarize_app(app, work / 'TaoScreen.zip')
        # 装订票据后的应用直接归档；Sparkle 下载 ZIP，无需挂载磁盘镜像。
        update_archive = output / 'macos' / version / package_name(version, arch, 'zip')
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(update_archive)], check=True)
        signature = subprocess.check_output([sparkle_tool('sign_update'), '--account', UPDATE_KEY_ACCOUNT,
                                             '-p', str(update_archive)], text=True).strip()
        feed = appcast_data(version, arch, notes, update_archive.stat().st_size, signature)
        verify_appcast(feed, version, arch, update_archive, info)
        # DMG 用于手动安装。
        disk_image = work / package.name
        create_disk_image(app, disk_image, version)
        notarize_disk_image(disk_image)
        shutil.move(disk_image, package)
    manifest = dict(version=version, platform='macos', arch=arch,
                    url=f'{RELEASE_ORIGIN}/macos/{version}/{package.name}',
                    sha256=hashlib.sha256(package.read_bytes()).hexdigest(),
                    size=package.stat().st_size, notes=notes)
    (output / f'taoscreen-macos-{arch}.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (output / f'taoscreen-appcast-{arch}.xml').write_bytes(feed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', nargs='?', help='三段数字，每段 0–9999；省略时自动确定')
    notes = parser.add_mutually_exclusive_group()
    notes.add_argument('--notes', help='更新说明；生成新版本时必填')
    notes.add_argument('--notes-file', type=pathlib.Path, help='UTF-8 更新说明文件')
    parser.add_argument('--upload', action='store_true', help='生成后上传 R2；清单生效后用户即可收到更新')
    parser.add_argument('--upload-only', action='store_true', help='不重新构建，上传已生成的本地发布文件')
    parser.add_argument('--init-update-key', action='store_true', help='仅初始化 TaoScreen 独立 Sparkle 密钥，不构建或发布')
    github = parser.add_mutually_exclusive_group()
    github.add_argument('--github-dmg', metavar='TAG', help='按 vX.Y.Z 构建临时签名的通用 DMG')
    github.add_argument('--github-sign-dmg', nargs=2, metavar=('TAG', 'APP'), help='按 vX.Y.Z 为通用 App 签名并生成公证 DMG')
    args = parser.parse_args()
    if args.github_dmg is not None or args.github_sign_dmg is not None:
        if args.version or args.notes or args.notes_file or args.upload or args.upload_only or args.init_update_key:
            parser.error('GitHub 打包与正式发布参数不能同时使用')
        if args.github_sign_dmg is not None:
            sign_github_dmg(*args.github_sign_dmg)
        else:
            build_github_dmg(args.github_dmg)
        return
    check_config(args)
    if args.init_update_key:
        if args.version or args.notes or args.notes_file or args.upload or args.upload_only:
            parser.error('--init-update-key 不能与构建或上传参数同时使用')
        init_update_key(update_key_path())
        return
    if args.notes_file:
        args.notes = args.notes_file.read_text(encoding='utf-8').strip()
    if args.version and not VERSION_PATTERN.fullmatch(args.version):
        parser.error('版本号无效')
    if not args.upload_only and not args.notes:
        parser.error('生成新版本时必须提供 --notes')
    if args.notes and len(args.notes.encode('utf-8')) > 16000:
        parser.error('更新说明超过 16000 字节')
    output.mkdir(parents=True, exist_ok=True)
    lock = (output / '.publish.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('另一项 TaoScreen 打包或发布正在运行，请等待完成')
    arch = subprocess.check_output(['uname', '-m'], text=True).strip()
    if arch not in ('arm64', 'x86_64'):
        raise SystemExit('架构不支持')
    plist_path = root / 'Resources/Info.plist'
    args.version = resolve_version(args.version, args.upload_only, arch, plist_path)
    if not VERSION_PATTERN.fullmatch(args.version):
        raise SystemExit(f'自动确定的版本号无效：{args.version}')
    print(f'版本号：{args.version}')
    if args.upload or args.upload_only:
        check_upload_ready(args.version, arch, fresh=not args.upload_only)
    if not args.upload_only:
        if version_parts(args.version) < version_parts(plistlib.loads(plist_path.read_bytes())['CFBundleShortVersionString']):
            parser.error('不能发布低于当前工程的版本')
        if any((output / 'macos' / args.version / package_name(args.version, arch, ext)).exists() for ext in ('dmg', 'zip')):
            raise SystemExit('安装包已存在，禁止覆盖已发布版本，请增加版本号')
        if SIGN_IDENTITY not in subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True):
            raise SystemExit(f'钥匙串中没有签名证书：{SIGN_IDENTITY}')
        if subprocess.run(['xcrun', 'notarytool', 'history', '--keychain-profile', NOTARY_PROFILE],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            raise SystemExit(f'公证配置 {NOTARY_PROFILE} 不可用，请先运行 xcrun notarytool store-credentials {NOTARY_PROFILE}')
        check_update_key(release_info(plist_path))
        # 桌面界面和输入测试共享主线程，串行运行完整套件，避免并发时限互相影响。
        subprocess.run(['swift', 'test', '--no-parallel'], cwd=root, check=True)
        subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests'], cwd=root, check=True)
        build(args.version, args.notes, arch, plist_path)
        print(f'发布文件：{output}')
    if args.upload or args.upload_only:
        upload(args.version, arch)
    else:
        print('未上传。实测后运行：python3 scripts/package-release.py --upload-only')


if __name__ == '__main__':
    main()
