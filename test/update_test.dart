import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heartrate/core/config/app_config.dart';
import 'package:heartrate/core/update/app_version.dart';
import 'package:heartrate/core/update/update_installer.dart';
import 'package:heartrate/core/update/update_service.dart';
import 'package:heartrate/ui/update/update_controller.dart';

/// 假的安装器桥：记录被调用了什么，返回预置结果。
final class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller({this.installAllowed = true, this.apk});

  String abi = 'arm64-v8a';
  bool installAllowed;
  ApkInfo? apk;
  int installCalls = 0;
  int settingsCalls = 0;

  @override
  Future<String> deviceAbi() async => abi;

  @override
  Future<ApkInfo?> inspectApk(String path) async => apk;

  @override
  Future<bool> canInstall() async => installAllowed;

  @override
  Future<bool> openInstallSettings() async {
    settingsCalls += 1;
    return true;
  }

  @override
  Future<bool> install(String path) async {
    installCalls += 1;
    return true;
  }

  @override
  Future<bool> openUrl(String url) async => true;
}

ApkInfo _apk({
  String packageName = AppConfig.applicationId,
  int versionCode = 1002101,
  bool sameSigner = true,
}) => ApkInfo(
  packageName: packageName,
  versionCode: versionCode,
  versionName: '1.0.1',
  signerSha256: sameSigner ? 'aa' : 'bb',
  sameSignerAsThisApp: sameSigner,
);

Map<String, Object?> _releaseJson({String tag = 'v1.0.1'}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/WJMA-GIT/heart-rate-share/releases/tag/$tag',
  'draft': false,
  'prerelease': false,
  'assets': [
    {
      'name': 'heartrate-1.0.1-armeabi-v7a-release.apk',
      'browser_download_url': 'https://example.invalid/arm.apk',
      'size': 16631766,
    },
    {
      'name': 'heartrate-1.0.1-arm64-v8a-release.apk',
      'browser_download_url': 'https://example.invalid/arm64.apk',
      'size': 19163258,
    },
    {
      'name': 'heartrate-1.0.1-x86_64-release.apk',
      'browser_download_url': 'https://example.invalid/x86.apk',
      'size': 20720254,
    },
  ],
};

void main() {
  group('版本比较（语义化，不是字符串比较）', () {
    test('1.0.9 不能比 1.0.17 新（字符串比较的经典坑：\'9\' > \'1\'）', () {
      expect(isRemoteNewer('1.0.17', '1.0.9'), isFalse);
      expect(isRemoteNewer('1.0.9', '1.0.17'), isTrue);
    });

    test('1.0.0 → 1.0.1 判定为新版本', () {
      expect(isRemoteNewer('1.0.0', '1.0.1'), isTrue);
      expect(isRemoteNewer('1.0.1', 'v1.0.1'), isFalse);
      expect(isRemoteNewer('1.0.1+2030', 'v1.0.1'), isFalse);
    });

    test('位数不同也按数值比', () {
      expect(isRemoteNewer('1.9.9', '1.10.0'), isTrue);
      expect(isRemoteNewer('1.0', '1.0.1'), isTrue);
      expect(isRemoteNewer('1.0.0', '1.0'), isFalse);
    });

    test('解析失败返回 null（不猜）', () {
      expect(isRemoteNewer('1.0.1', 'not-a-version'), isNull);
      expect(isRemoteNewer('', '1.0.1'), isNull);
    });
  });

  group('release 解析与 ABI 选包', () {
    test('arm64 设备选 arm64 包，不装错包', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => _releaseJson(),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateAvailable>());
      final available = result as UpdateAvailable;
      expect(available.release.version.toString(), '1.0.1');
      expect(available.asset!.name, contains('arm64-v8a'));
      expect(available.asset!.size, 19163258);
    });

    test('未知 ABI 不给包，让用户自己去 Release 页面', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => _releaseJson(),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'unknown',
      ) as UpdateAvailable;
      expect(result.asset, isNull);
    });

    test('已是最新时不提示更新', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => _releaseJson(),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.1',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateUpToDate>());
    });

    test('draft / prerelease 一律忽略', () async {
      final json = _releaseJson()..['prerelease'] = true;
      final checker = UpdateChecker(
        fetcher: (_) async => json,
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateCheckFailed>());
    });
  });

  group('资产选择：Windows zip 存在时 Android 仍只挑 APK', () {
    Map<String, Object?> releaseWithZip() => {
      'tag_name': 'v1.0.2',
      'html_url':
          'https://github.com/WJMA-GIT/heart-rate-share/releases/tag/v1.0.2',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'heartrate-1.0.2-windows-x64.zip',
          'browser_download_url': 'https://example.invalid/win.zip',
          'size': 12116457,
        },
        {
          'name': 'heartrate-1.0.2-arm64-v8a-release.apk',
          'browser_download_url': 'https://example.invalid/arm64.apk',
          'size': 19229234,
        },
      ],
    };

    test('Android 只会选 APK，绝不选 Windows zip', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => releaseWithZip(),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.1',
        deviceAbi: 'arm64-v8a',
      ) as UpdateAvailable;
      expect(result.asset, isNotNull);
      expect(result.asset!.name, endsWith('.apk'));
      expect(result.asset!.name, contains('arm64-v8a'));
      expect(result.asset!.name, isNot(contains('windows')));
    });

    test('v1.0.2 能被识别为更新（相对 1.0.1）', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => releaseWithZip(),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.1',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateAvailable>());
      final available = result as UpdateAvailable;
      expect(available.release.version.toString(), '1.0.2');
    });

    test('assets 里有 exe 时也不会被选中（只认 .apk）', () async {
      final json = {
        'tag_name': 'v1.0.3',
        'html_url':
            'https://github.com/WJMA-GIT/heart-rate-share/releases/tag/v1.0.3',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'heartrate-1.0.3-windows-x64.exe',
            'browser_download_url': 'https://example.invalid/win.exe',
            'size': 25000000,
          },
          {
            'name': 'heartrate-1.0.3-arm64-v8a-release.apk',
            'browser_download_url': 'https://example.invalid/arm64.apk',
            'size': 19000000,
          },
        ],
      };
      final checker = UpdateChecker(
        fetcher: (_) async => json,
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.2',
        deviceAbi: 'arm64-v8a',
      ) as UpdateAvailable;
      expect(result.asset!.name, endsWith('.apk'));
      expect(result.asset!.name, isNot(contains('.exe')));
    });

    test('只有 exe 没有 APK 时：不给包（不装错东西）', () async {
      final json = {
        'tag_name': 'v1.0.3',
        'html_url':
            'https://github.com/WJMA-GIT/heart-rate-share/releases/tag/v1.0.3',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'heartrate-1.0.3-windows-x64.exe',
            'browser_download_url': 'https://example.invalid/win.exe',
            'size': 1,
          },
        ],
      };
      final checker = UpdateChecker(
        fetcher: (_) async => json,
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.2',
        deviceAbi: 'arm64-v8a',
      ) as UpdateAvailable;
      expect(result.asset, isNull);
    });

    test('只有 zip 没有 APK 时：给"没有匹配安装包"，不去装错包', () async {
      final json = releaseWithZip()
        ..['assets'] = [
          {
            'name': 'heartrate-1.0.2-windows-x64.zip',
            'browser_download_url': 'https://example.invalid/win.zip',
            'size': 1,
          },
        ];
      final checker = UpdateChecker(
        fetcher: (_) async => json,
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.1',
        deviceAbi: 'arm64-v8a',
      ) as UpdateAvailable;
      expect(result.asset, isNull);
    });
  });

  group('检查失败的文案与重试', () {
    test('404（私有仓库/没有 Release）要说清楚，不能只说"网络错误"', () async {
      final checker = UpdateChecker(
        fetcher: (_) async => throw const UpdateHttpException(404),
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      ) as UpdateCheckFailed;
      expect(result.reason, contains('404'));
      expect(result.reason, contains('私有'));
    });

    test('403 + 配额耗尽 → 限流提示，且不重试', () async {
      var calls = 0;
      final checker = UpdateChecker(
        fetcher: (_) async {
          calls += 1;
          throw const UpdateHttpException(403, rateLimitRemaining: 0);
        },
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      ) as UpdateCheckFailed;
      expect(result.reason, contains('限流'));
      expect(calls, 1, reason: '4xx 重试没意义');
    });

    test('网络抖动只重试一次，第二次成功就用结果', () async {
      var calls = 0;
      final checker = UpdateChecker(
        fetcher: (_) async {
          calls += 1;
          if (calls == 1) throw const SocketException('offline');
          return _releaseJson();
        },
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateAvailable>());
      expect(calls, 2);
    });

    test('连续失败就报错，不无限重试', () async {
      var calls = 0;
      final checker = UpdateChecker(
        fetcher: (_) async {
          calls += 1;
          throw const SocketException('offline');
        },
        retryDelay: Duration.zero,
      );
      final result = await checker.check(
        currentVersion: '1.0.0',
        deviceAbi: 'arm64-v8a',
      );
      expect(result, isA<UpdateCheckFailed>());
      expect(calls, 2, reason: '总共两次（原始 + 一次重试）');
    });
  });

  group('下载：写入、进度、完整性、取消', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('hr-update-test-');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    const asset = ReleaseAsset(
      name: 'heartrate-1.0.1-arm64-v8a-release.apk',
      downloadUrl: 'https://example.invalid/arm64.apk',
      size: 10,
    );

    test('正常下载：字节数、进度回调、落地文件都在', () async {
      final progress = <int>[];
      final downloader = UpdateDownloader(
        directory: temp,
        opener: (_) async => (
          body: Stream.fromIterable([
            [1, 2, 3, 4],
            [5, 6, 7, 8, 9, 10],
          ]),
          contentLength: 10,
        ),
      );
      final file = await downloader.download(
        asset: asset,
        isCancelled: () => false,
        onProgress: (received, total) => progress.add(received),
      );
      expect(await file.length(), 10);
      expect(progress.last, 10);
      expect(progress, isNotEmpty);
    });

    test('下载被打断（字节数不够）→ 报错并删掉半截文件', () async {
      final downloader = UpdateDownloader(
        directory: temp,
        opener: (_) async => (
          body: Stream.fromIterable([
            [1, 2, 3],
          ]),
          contentLength: 10,
        ),
      );
      await expectLater(
        downloader.download(
          asset: asset,
          isCancelled: () => false,
          onProgress: (_, _) {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        temp.listSync().where((entity) => entity.path.endsWith('.apk')),
        isEmpty,
        reason: '半截包必须删掉，不能留着被误装',
      );
    });

    test('取消：抛 UpdateCancelled 且不留文件', () async {
      var sent = 0;
      final downloader = UpdateDownloader(
        directory: temp,
        opener: (_) async => (
          body:
              Stream.fromIterable([
                [1, 2, 3],
                [4, 5, 6],
              ]).asyncMap((chunk) async {
                sent += 1;
                return chunk;
              }),
          contentLength: 6,
        ),
      );
      await expectLater(
        downloader.download(
          asset: asset,
          isCancelled: () => sent >= 1,
          onProgress: (_, _) {},
        ),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(
        temp.listSync().where((entity) => entity.path.endsWith('.apk')),
        isEmpty,
      );
    });
  });

  group('安装前校验（任何一项不符都中止）', () {
    late Directory temp;
    late File apkFile;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('hr-install-test-');
      apkFile = File('${temp.path}/heartrate-1.0.1-arm64-v8a-release.apk');
      await apkFile.writeAsBytes(List<int>.filled(16, 7));
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    UpdateController controllerWith(_FakeInstaller installer) {
      final controller = UpdateController(
        checker: UpdateChecker(
          fetcher: (_) async => _releaseJson(),
          retryDelay: Duration.zero,
        ),
        downloader: UpdateDownloader(
          directory: temp,
          opener: (_) async =>
              (body: Stream.value(utf8.encode('x' * 16)), contentLength: 16),
        ),
        installer: installer,
        appInfo: () async => (version: '1.0.0', buildNumber: 1002100),
      );
      controller.filePath = apkFile.path;
      controller.currentVersionCode = 1002100;
      return controller;
    }

    test('没给"安装未知应用"权限：跳设置页并说明，不静默失败', () async {
      final installer = _FakeInstaller(installAllowed: false, apk: _apk());
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.settingsCalls, 1);
      expect(installer.installCalls, 0);
      expect(controller.message, contains('安装未知应用'));
      expect(controller.phase, UpdatePhase.ready);
    });

    test('签名不一致 → 中止，绝不拉起安装器', () async {
      final installer = _FakeInstaller(apk: _apk(sameSigner: false));
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.installCalls, 0);
      expect(controller.message, contains('签名'));
      expect(controller.phase, UpdatePhase.failed);
    });

    test('包名不符 → 中止', () async {
      final installer = _FakeInstaller(apk: _apk(packageName: 'com.evil.app'));
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.installCalls, 0);
      expect(controller.message, contains('包名'));
    });

    test('versionCode 不比当前大 → 中止（防止装回旧包）', () async {
      final installer = _FakeInstaller(apk: _apk(versionCode: 1002100));
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.installCalls, 0);
      expect(controller.message, contains('不比当前版本新'));
    });

    test('解析不出 APK → 中止并提示可能是下载损坏', () async {
      final installer = _FakeInstaller();
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.installCalls, 0);
      expect(controller.message, contains('无法解析'));
    });

    test('全部通过才拉起系统安装器', () async {
      final installer = _FakeInstaller(apk: _apk());
      final controller = controllerWith(installer);
      await controller.install();
      expect(installer.installCalls, 1);
      expect(controller.message, contains('系统安装器'));
    });
  });
}
