import '../../ble/ble_models.dart';
import '../profile/nickname.dart';
import '../../room/room_address.dart';
import '../../room/room_transport.dart';
import '../../room/room_client.dart';

/// 轻量中文文案层：当前只有中文，集中常量即可；暂不引入完整 l10n 工具链。
abstract final class Zh {
  static const appName = '共享心率';
  static const heartRateTitle = '当前心率';
  static const roomTitle = '房间';
  static const settingsTitle = '设置';
  static const navHeartRate = '心率';
  static const navRoom = '房间';
  static const navSettings = '设置';

  static const waitingHeartRate = '等待心率数据';
  static const scanDevices = '扫描设备';
  static const selectHeartRateDevice = '选择心率设备';
  static const connectHeartRateDevice = '连接心率设备';
  static const disconnect = '断开连接';
  static const unnamedDevice = '未命名心率设备';
  static const contactSupported = '已接触';
  static const contactNotSupported = '未接触';
  static const contactUnknown = '设备不提供佩戴状态';
  static const sensorContactLabel = '佩戴状态';
  static const rrIntervalsLabel = 'RR 间值';
  static const adapterLabel = '蓝牙适配器';
  static const connectionStatusLabel = '连接状态';
  static const bleErrorTitle = '蓝牙连接失败，请按提示处理后重试';
  static const bleReconnectFailed = '多次自动重连仍未成功，请确认心率带已佩戴且电量正常后重新连接。';

  // ---- 连接方式 / 最近连接 ----
  static const officialServer = '官方服务器';
  static const officialServerConnect = '连接';
  static const officialServerSwitch = '切换';
  static const roomModeChoose = '选择连接方式后才能进入房间';
  static const connectOfficialServer = '连接官方服务器';
  static const createLocalRoom = '在本机创建房间';
  static const localRoomHint = '本机房间只在这台手机上，其他设备需要用同一局域网地址加入';
  static const recentConnections = '最近连接';
  static const recentEmpty = '还没有连接记录';
  static const forgetProfile = '删除这条记录';
  static const manualAddressSection = '高级：手动填写地址';
  static const serverEndpointLabel = '服务器地址';
  static const secureConnection = '加密连接（wss）';
  static const plainConnection = '明文连接（ws，仅限本机/局域网）';
  static const certPinned = '已钉住证书指纹';
  static const certSystemCa = '使用系统 CA 校验';

  // ---- 设备列表 ----
  static const heartRateDevices = '心率设备';
  static const noHeartRateDevices = '未扫描到设备。点「扫描设备」开始搜索。';
  static const connectNow = '连接';
  static const connectedDevice = '已连接';
  static const removeFromList = '从列表移除';
  static const deviceRemoved = '已从列表移除该设备';
  static const rssiLabel = '信号';
  static const deviceIdLabel = '标识';

  static String roomErrorCode(RoomErrorCode code) => switch (code) {
    RoomErrorCode.certificateUntrusted => '服务器证书未通过系统 CA 校验（可能是自签证书）。',
    RoomErrorCode.certificateHostMismatch =>
      '服务器证书与访问的域名不匹配：证书可能是 *.mawj.asia 通配，'
          '必须用 relay.mawj.asia 这类子域访问（根域不在证书范围内）。',
    RoomErrorCode.certificatePinnedMismatch => '服务器证书与内置指纹不一致，已拒绝连接。',
    RoomErrorCode.tlsHandshake => 'TLS 握手失败，请确认服务端已开启 wss。',
    RoomErrorCode.dnsFailure => '域名解析失败：找不到服务器地址。请检查网络连接与域名是否正确。',
    RoomErrorCode.connectionRefused => '服务器拒绝连接，请确认服务已启动、端口正确。',
    RoomErrorCode.connectionTimeout => '连接超时：服务器没有响应，请检查 IPv6 是否可用、端口是否开放。',
    RoomErrorCode.ipv6Unreachable =>
      '当前网络不支持 IPv6。这台服务器只有 IPv6 地址（AAAA 记录），'
          '请改用支持 IPv6 的网络，或请管理员提供 IPv4 入口。',
    RoomErrorCode.handshakeRejected => '服务器未接受 WebSocket 升级，请检查反向代理配置。',
    RoomErrorCode.badRequest => '服务器返回 400：请求被拒绝，通常是房间号或参数格式不对。',
    RoomErrorCode.endpointNotFound =>
      '服务器返回 404：路径或房间号不对（路径应为 /ws，且带正确的 ?room=短码）。',
    RoomErrorCode.unknown => '连接失败，请查看诊断日志。',
  };

  static const roomNumber = '房间号';
  static const roomNumberHint = '输入房间号加入';
  static const roomNumberRequired = '请输入房间号后再加入。';
  static const roomNotJoined = '未加入房间';
  static const roomNumberTapToCopy = '点击房间号复制';
  static const copyRoomNumber = '复制房间号';
  static const roomCodeCopied = '房间号已复制';
  static const serverAddress = '服务器地址';
  static const serverAddressHint =
      '域名或 IP，可带端口，例如 heart.example.com 或 192.168.1.10:8765';
  static const copyServerAddress = '复制地址';
  static const serverAddressCopied = '地址已复制';
  static const serverAddressTapToCopy = '点击地址复制';
  static const joinRoom = '加入房间';
  static const leaveRoom = '退出房间';
  static const hostRelay = '创建本地房间（开发模式）';
  static const stopRelay = '关闭本地房间';
  static const roomMembers = '房间成员';
  static const connectFailedTitle = '连接失败';
  static const connectDiagnostics = '诊断信息（可复制给管理员）';
  static const copyDiagnostics = '复制诊断信息';
  static const connectDiagnosticsCopied = '诊断信息已复制';
  static const close = '关闭';
  static const customServer = '自定义服务器';
  static const profileDetails = '连接详情';
  static const seeDiagnostics = '诊断';
  static const roomCodeRuleHint = '房间号：字母、数字、下划线、短横线，1–64 位';
  static const useSecondaryServer = '切换备用端口（443 被运营商封时用）';
  static const officialServerSecondary = '备用线路';
  static const noRoomMembers = '暂无成员，等待其他设备加入';
  static const online = '在线';
  static const offline = '已离线';
  static const sequenceLabel = '序号';
  static const guestUser = '访客';
  static const guestNicknameHint = '当前昵称为「访客」，可到「设置」修改。';
  static const developmentTransportWarning = '使用 ws:// 时数据为明文，公网连接请使用 wss://。';

  static const nicknameLabel = '我的昵称';
  static const nicknameHint = '输入 1–16 个字符，支持中文';
  static const nicknameSave = '保存昵称';
  static const nicknameSaved = '昵称已保存';
  static const nicknameEmptyError = '昵称不能为空';
  static const nicknameTooLongError = '昵称最多 16 个字符';
  static const nicknameSaveFailed = '昵称保存失败，请重试。';

  static const debugDiagnostics = '调试诊断';
  static const debugDescription = '默认关闭；开启后记录详细心率设备日志';
  static const exportLogs = '导出日志';
  static const shareLogFile = '分享日志文件';
  static const logsInitializing = '日志正在初始化，请稍后重试';
  static const roomAddressHelp = '房间号在「房间」页填写；服务器地址可留空使用默认配置。';
  static const aboutVersion = '版本信息';
  static const loadingVersion = '正在读取版本信息…';
  static const versionUnavailable = '暂时无法读取版本信息';

  static const bleAdapterDebug = '蓝牙适配器状态';
  static const connectionStateDebug = '连接状态机';
  static const connectedDeviceDebug = '已连接设备';
  static const rawHrsDebug = '原始 HRS 字节';
  static const discoveredDevices = '扫描到的设备';
  static const recentDiagnostics = '最近诊断信息';

  static String blePhase(BleConnectionPhase phase) => switch (phase) {
    BleConnectionPhase.idle => '空闲',
    BleConnectionPhase.adapterOff => '蓝牙未开启',
    BleConnectionPhase.permissionDenied => '请授予附近设备权限',
    BleConnectionPhase.scanning => '正在扫描',
    BleConnectionPhase.connecting => '正在连接',
    BleConnectionPhase.discovering => '正在读取设备服务',
    BleConnectionPhase.subscribed => '已连接，正在接收心率',
    BleConnectionPhase.disconnecting => '正在断开连接',
    BleConnectionPhase.reconnecting => '连接已断开，正在自动重连',
    BleConnectionPhase.reconnectFailed => '自动重连失败，请手动重连',
    BleConnectionPhase.error => '连接异常',
  };

  static String adapterState(String state) => switch (state) {
    'on' => '已开启',
    'off' => '蓝牙未开启',
    'unauthorized' => '请授予附近设备权限',
    'unavailable' => '当前设备不支持蓝牙',
    'unknown' => '未知',
    _ => state,
  };

  static String roomState(RoomConnectionState state) => switch (state) {
    RoomConnectionState.disconnected => '未连接',
    RoomConnectionState.connecting => '正在连接',
    RoomConnectionState.connected => '已连接',
    RoomConnectionState.error => '连接失败',
  };

  static String contact(bool? value) => switch (value) {
    true => contactSupported,
    false => contactNotSupported,
    null => contactUnknown,
  };

  static String nicknameError(NicknameValidationError error) => switch (error) {
    NicknameValidationError.empty => nicknameEmptyError,
    NicknameValidationError.tooLong => nicknameTooLongError,
  };

  static String bleError(Object error) {
    final text = '$error';
    if (text.contains('permission') || text.contains('unauthorized')) {
      return '请授予附近设备权限，并确认蓝牙已开启后重试。';
    }
    if (text.contains('BLE adapter unavailable')) {
      return '蓝牙未开启或当前设备不可用，请开启蓝牙后重试。';
    }
    if (text.contains('Scan first')) {
      return '请先扫描设备，再选择要连接的心率设备。';
    }
    if (text.contains('0x2A37 not found')) {
      return '该设备不支持标准心率服务，请选择支持 HRS 的心率设备。';
    }
    if (text.contains('not implemented')) {
      return '当前平台尚未支持心率采集，请使用 Android 设备连接心率设备。';
    }
    return '操作失败，请确认蓝牙已开启、心率设备处于可连接状态后重试。';
  }

  static String roomError(Object error) {
    final addressError = error is RoomAddressException ? error.reason : null;
    return switch (addressError) {
      RoomAddressError.empty => '请输入服务器地址或房间号后重试。',
      RoomAddressError.unsupportedScheme =>
        '地址格式不正确，请使用域名、IP，或 ws://、wss:// 开头的地址。',
      RoomAddressError.invalidHost => '服务器地址中的域名或 IP 不正确，请检查后重试。',
      RoomAddressError.invalidPort => '端口必须是 1–65535 之间的数字，请检查后重试。',
      RoomAddressError.invalidRoomCode => '房间号只能使用字母、数字、下划线和短横线，长度 1–64。',
      RoomAddressError.insecureScheme =>
        '官方服务器必须使用 wss://（443 端口）。地址若没有写协议，请确认已带 wss://。',
      null => '无法加入房间，请检查网络、房间号和服务器地址后重试。',
    };
  }

  static String exportError(Object error) => '日志导出失败，请确认系统分享功能可用后重试。';
}
