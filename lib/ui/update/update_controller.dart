import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/update/update_installer.dart';
import '../../core/update/update_service.dart';

enum UpdatePhase {
  /// 还没检查过。
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
  failed,
}

typedef AppInfoLoader = Future<({String version, int buildNumber})> Function();

/// 检查更新 → 下载 → 校验 → 拉起系统安装器 的状态机。
///
/// 边界：只有用户点按钮才会动作（没有后台轮询、没有静默安装、不上传任何东西）。
final class UpdateController extends ChangeNotifier {
  UpdateController({
    UpdateChecker? checker,
    UpdateDownloader? downloader,
    UpdateInstaller? installer,
    AppInfoLoader? appInfo,
  }) : _checker = checker ?? UpdateChecker(),
       _downloader = downloader ?? UpdateDownloader(),
       _installer = installer ?? const PlatformUpdateInstaller(),
       _appInfo = appInfo ?? _loadAppInfo;

  final UpdateChecker _checker;
  final UpdateDownloader _downloader;
  final UpdateInstaller _installer;
  final AppInfoLoader _appInfo;

  static Future<({String version, int buildNumber})> _loadAppInfo() async {
    final info = await PackageInfo.fromPlatform();
    return (
      version: info.version,
      buildNumber: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  UpdatePhase phase = UpdatePhase.idle;
  String message = '';
  String currentVersion = '';
  int currentVersionCode = 0;
  String deviceAbi = '';
  ReleaseInfo? release;
  ReleaseAsset? asset;
  String? filePath;
  int receivedBytes = 0;
  int totalBytes = 0;
  bool _cancelled = false;
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.installing;

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;

  String get releasesPage => _checker.releasesPage;

  Future<void> loadCurrentVersion() async {
    try {
      final info = await _appInfo();
      currentVersion = info.version;
      currentVersionCode = info.buildNumber;
    } catch (_) {
      currentVersion = '';
      currentVersionCode = 0;
    }
    deviceAbi = await _installer.deviceAbi();
    _notify();
  }

  Future<void> check() async {
    if (busy) return;
    if (currentVersion.isEmpty) await loadCurrentVersion();
    phase = UpdatePhase.checking;
    message = '';
    _notify();

    final result = await _checker.check(
      currentVersion: currentVersion,
      deviceAbi: deviceAbi,
    );
    switch (result) {
      case UpdateUpToDate(:final current):
        phase = UpdatePhase.upToDate;
        message = '已是最新版本 $current';
      case UpdateAvailable(:final release, :final asset, :final deviceAbi):
        this.release = release;
        this.asset = asset;
        this.deviceAbi = deviceAbi;
        phase = UpdatePhase.available;
        message = asset == null
            ? '发现 ${release.version}，但没有适配 $deviceAbi 的安装包，请到 Release 页面手动下载'
            : '发现新版本 ${release.version}（${_sizeLabel(asset.size)}）';
      case UpdateCheckFailed(:final reason):
        phase = UpdatePhase.failed;
        message = reason;
    }
    _notify();
  }

  Future<void> download() async {
    final target = asset;
    if (target == null || busy) return;
    _cancelled = false;
    phase = UpdatePhase.downloading;
    receivedBytes = 0;
    totalBytes = target.size;
    message = '正在下载…';
    _notify();
    try {
      final file = await _downloader.download(
        asset: target,
        isCancelled: () => _cancelled,
        onProgress: (received, total) {
          receivedBytes = received;
          if (total != null) totalBytes = total;
          final now = DateTime.now();
          // 每 ~120ms 刷一次界面，别让几千个 chunk 把 UI 拖死。
          if (now.difference(_lastProgressNotify).inMilliseconds > 120) {
            _lastProgressNotify = now;
            _notify();
          }
        },
      );
      filePath = file.path;
      if (_cancelled) {
        phase = UpdatePhase.available;
        message = '已取消下载';
        filePath = null;
      } else {
        phase = UpdatePhase.ready;
        message = '下载完成（${_sizeLabel(receivedBytes)}），可以安装';
      }
    } on UpdateCancelled {
      phase = UpdatePhase.available;
      message = '已取消下载';
      filePath = null;
    } catch (error) {
      phase = UpdatePhase.failed;
      message = '下载失败：$error';
      filePath = null;
    }
    _notify();
  }

  void cancel() {
    if (phase != UpdatePhase.downloading) return;
    _cancelled = true;
  }

  /// 校验 + 拉起系统安装器。任何一项不符都中止并说明原因（绝不"凑合装"）。
  Future<void> install() async {
    final path = filePath;
    if (path == null || busy) return;
    phase = UpdatePhase.installing;
    message = '正在校验安装包…';
    _notify();

    if (!await _installer.canInstall()) {
      phase = UpdatePhase.ready;
      message = '需要先允许"安装未知应用"，已为你打开设置页；授权后回来再点安装';
      await _installer.openInstallSettings();
      _notify();
      return;
    }

    final info = await _installer.inspectApk(path);
    if (info == null) {
      phase = UpdatePhase.failed;
      message = '安装包无法解析（可能下载损坏），请重试或到 Release 页面手动下载';
      _notify();
      return;
    }
    if (info.packageName != AppConfig.applicationId) {
      phase = UpdatePhase.failed;
      message = '安装包包名不符（${info.packageName}），已中止';
      _notify();
      return;
    }
    if (!info.sameSignerAsThisApp) {
      phase = UpdatePhase.failed;
      message = '安装包签名与本机版本不一致，已中止（覆盖安装必须同签名）';
      _notify();
      return;
    }
    if (info.versionCode <= currentVersionCode) {
      phase = UpdatePhase.failed;
      message = '这个包（versionCode ${info.versionCode}）不比当前版本新，已中止';
      _notify();
      return;
    }

    final started = await _installer.install(path);
    phase = started ? UpdatePhase.ready : UpdatePhase.failed;
    message = started ? '已拉起系统安装器，请在弹窗里确认安装' : '无法拉起系统安装器，请到 Release 页面手动下载';
    _notify();
  }

  Future<void> openReleasePage() async {
    await _installer.openUrl(_checker.releasesPage);
  }

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '大小未知';
    final mb = bytes / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(bytes / 1024).round()} KB';
  }

  void _notify() {
    if (!hasListeners) return;
    notifyListeners();
  }
}
