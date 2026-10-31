import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_version.dart';

/// 一次 Release 里的一个安装包。
final class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;

  /// GitHub 给的字节数；0 表示未知。
  final int size;
}

/// 解析后的 latest release（已排除 draft / prerelease）。
final class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.pageUrl,
    required this.assets,
  });

  final String tag;
  final AppVersion version;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  /// 资产命名：`heartrate-<ver>-<abi>-release.apk`（arm64-v8a / armeabi-v7a / x86_64）。
  ReleaseAsset? assetForAbi(String abi) {
    if (abi.isEmpty || abi == 'unknown') return null;
    for (final asset in assets) {
      if (!asset.name.endsWith('.apk')) continue;
      if (asset.name.contains('-$abi-')) return asset;
    }
    return null;
  }
}

sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

final class UpdateUpToDate extends UpdateCheckResult {
  const UpdateUpToDate(this.current);
  final String current;
}

final class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable({
    required this.release,
    required this.asset,
    required this.deviceAbi,
  });
  final ReleaseInfo release;

  /// 没有匹配本机 ABI 的包时为 null（UI 引导去 Release 页面手动下）。
  final ReleaseAsset? asset;
  final String deviceAbi;
}

final class UpdateCheckFailed extends UpdateCheckResult {
  const UpdateCheckFailed(this.reason);
  final String reason;
}

final class UpdateHttpException implements Exception {
  const UpdateHttpException(
    this.status, {
    this.rateLimitRemaining,
    this.message,
  });
  final int status;
  final int? rateLimitRemaining;
  final String? message;

  @override
  String toString() => 'HTTP $status${message == null ? '' : ': $message'}';
}

final class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

typedef ReleaseFetcher = Future<Map<String, Object?>> Function(Uri uri);

/// 抓 latest release 的 JSON。注入点：单测直接给假数据，不碰网络。
Future<Map<String, Object?>> fetchReleaseJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 8));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'heart-rate-share-app');
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw UpdateHttpException(
        response.statusCode,
        rateLimitRemaining: int.tryParse(
          response.headers.value('x-ratelimit-remaining') ?? '',
        ),
        message: body.length > 200 ? body.substring(0, 200) : body,
      );
    }
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

/// 检查更新：只读 GitHub Releases，不上传任何信息。
final class UpdateChecker {
  UpdateChecker({
    ReleaseFetcher? fetcher,
    this.owner = 'WJMA-GIT',
    this.repo = 'heart-rate-share',
    this.retryDelay = const Duration(seconds: 2),
  }) : _fetch = fetcher ?? fetchReleaseJson;

  final ReleaseFetcher _fetch;
  final String owner;
  final String repo;
  final Duration retryDelay;

  Uri get latestUri =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  String get releasesPage => 'https://github.com/$owner/$repo/releases/latest';

  /// 语义化比较 + 选包。网络错误只重试一次（弱网抖动够用，绝不无限重试）。
  Future<UpdateCheckResult> check({
    required String currentVersion,
    required String deviceAbi,
  }) async {
    Map<String, Object?> json;
    try {
      json = await _fetchWithRetry();
    } on UpdateHttpException catch (error) {
      return UpdateCheckFailed(_describeHttp(error));
    } on TimeoutException {
      return const UpdateCheckFailed('网络超时，请检查网络后重试');
    } on SocketException {
      return const UpdateCheckFailed('网络不可用，请检查网络后重试');
    } on FormatException {
      return const UpdateCheckFailed('更新服务返回的数据无法解析');
    } catch (error) {
      return UpdateCheckFailed('检查更新失败：$error');
    }

    final ReleaseInfo release;
    try {
      release = _parse(json);
    } on FormatException {
      return const UpdateCheckFailed('更新服务返回的数据无法解析');
    } on TypeError {
      return const UpdateCheckFailed('更新服务返回的数据无法解析');
    }

    final newer = isRemoteNewer(currentVersion, release.version.toString());
    if (newer == null) {
      return const UpdateCheckFailed('无法比较版本号，请到 Release 页面手动确认');
    }
    if (!newer) return UpdateUpToDate(currentVersion);
    return UpdateAvailable(
      release: release,
      asset: release.assetForAbi(deviceAbi),
      deviceAbi: deviceAbi,
    );
  }

  Future<Map<String, Object?>> _fetchWithRetry() async {
    try {
      return await _fetch(latestUri);
    } on UpdateHttpException catch (error) {
      // 4xx（含 404/403 限流）重试也没用，立刻回；5xx 才重试一次。
      if (error.status < 500) rethrow;
    } on SocketException {
      await Future<void>.delayed(retryDelay);
      return _fetch(latestUri);
    } on TimeoutException {
      await Future<void>.delayed(retryDelay);
      return _fetch(latestUri);
    }
    await Future<void>.delayed(retryDelay);
    return _fetch(latestUri);
  }

  String _describeHttp(UpdateHttpException error) {
    if (error.status == 404) {
      // 匿名访问私有仓库/没有 Release 都是 404，必须说清楚，别让用户以为网络坏了。
      return 'GitHub 返回 404：仓库可能是私有的或还没有 Release；请点"打开 Release 页面"';
    }
    if (error.status == 403 && (error.rateLimitRemaining ?? 1) == 0) {
      return 'GitHub API 限流（每小时 60 次），请稍后再试';
    }
    return 'GitHub 返回 HTTP ${error.status}';
  }

  ReleaseInfo _parse(Map<String, Object?> json) {
    if (json['draft'] == true || json['prerelease'] == true) {
      throw const FormatException('draft or prerelease');
    }
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) throw const FormatException('tag');
    final pageUrl = json['html_url'];
    final assets = <ReleaseAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map) continue;
        final name = raw['name'];
        final url = raw['browser_download_url'];
        if (name is! String || url is! String) continue;
        final size = raw['size'];
        assets.add(
          ReleaseAsset(
            name: name,
            downloadUrl: url,
            size: size is int ? size : 0,
          ),
        );
      }
    }
    return ReleaseInfo(
      tag: tag,
      version: AppVersion.parse(tag),
      pageUrl: pageUrl is String ? pageUrl : releasesPage,
      assets: assets,
    );
  }
}

typedef AssetStreamOpener =
    Future<({Stream<List<int>> body, int? contentLength})> Function(Uri uri);

Future<({Stream<List<int>> body, int? contentLength})> openAssetStream(
  Uri uri,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.userAgentHeader, 'heart-rate-share-app');
  final response = await request.close();
  if (response.statusCode != 200) {
    client.close(force: true);
    throw UpdateHttpException(response.statusCode);
  }
  // 流结束后再关连接：交给调用方读完。
  return (
    body: response.handleError((Object error) {
      client.close(force: true);
      throw error;
    }),
    contentLength: response.contentLength > 0 ? response.contentLength : null,
  );
}

/// 下载到应用私有目录（`<support>/updates/`），可取消，落地后校验字节数。
final class UpdateDownloader {
  UpdateDownloader({AssetStreamOpener? opener, this.directory})
    : _open = opener ?? openAssetStream;

  final AssetStreamOpener _open;

  /// 下载目录（缺省：应用私有 `<support>/updates`；单测可注入临时目录）。
  final Directory? directory;

  Future<File> download({
    required ReleaseAsset asset,
    required void Function(int received, int? total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final directory = this.directory ?? await _updatesDirectory();
    await directory.create(recursive: true);
    // 文件名里带版本，避免上一次的残留被误装。
    final target = File('${directory.path}/${asset.name}');
    if (await target.exists()) await target.delete();

    final opened = await _open(Uri.parse(asset.downloadUrl));
    final expected =
        opened.contentLength ?? (asset.size > 0 ? asset.size : null);
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in opened.body) {
        if (isCancelled()) throw const UpdateCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, expected);
      }
    } on UpdateCancelled {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    } catch (error) {
      await sink.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await sink.close();

    if (expected != null && received != expected) {
      await target.delete();
      throw StateError('下载不完整：收到 $received 字节，期望 $expected 字节');
    }
    return target;
  }

  Future<Directory> _updatesDirectory() async {
    // 应用私有目录（/data/user/0/<pkg>/files/updates）：不进外部存储、别的 App 读不到。
    final Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      return Directory('${Directory.systemTemp.path}/heartrate-updates');
    }
    return Directory('${base.path}/updates');
  }
}
