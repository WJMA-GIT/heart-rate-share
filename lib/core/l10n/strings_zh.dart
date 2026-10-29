import '../../ble/ble_models.dart';
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
  static const selectHeartRateStrap = '选择心率带';
  static const connectHeartRateStrap = '连接心率带';
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

  static const roomShortCode = '房间短码';
  static const roomShortCodeHint = '请输入房间短码';
  static const relayAddress = '中继地址（手动连接备用）';
  static const relayAddressHint = '192.168.1.10:8765 或 ws://主机地址:8765';
  static const joinRoom = '加入房间';
  static const leaveRoom = '退出房间';
  static const hostRelay = '创建本地房间（开发模式）';
  static const stopRelay = '关闭本地房间';
  static const roomMembers = '房间成员';
  static const noRoomMembers = '暂无成员，等待其他设备加入';
  static const online = '在线';
  static const offline = '已离线';
  static const sequenceLabel = '序号';
  static const guestUser = '访客';
  static const localRoomAddress = '本地房间地址';
  static const developmentTransportWarning =
      '当前为 ws:// 开发模式，请勿在不可信的局域网中共享敏感数据。';

  static const debugDiagnostics = '调试诊断';
  static const debugDescription = '默认关闭；开启后记录详细心率设备日志';
  static const exportLogs = '导出日志';
  static const shareLogFile = '分享日志文件';
  static const logsInitializing = '日志正在初始化，请稍后重试';
  static const roomAddressHelp = '房间短码和中继地址请在「房间」页填写。';
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

  static String bleError(Object error) {
    final text = '$error';
    if (text.contains('permission') || text.contains('unauthorized')) {
      return '请授予附近设备权限，并确认蓝牙已开启后重试。';
    }
    if (text.contains('BLE adapter unavailable')) {
      return '蓝牙未开启或当前设备不可用，请开启蓝牙后重试。';
    }
    if (text.contains('Scan first')) {
      return '请先扫描设备，再选择要连接的心率带。';
    }
    if (text.contains('0x2A37 not found')) {
      return '该设备不支持标准心率服务，请选择支持 HRS 的心率带。';
    }
    if (text.contains('not implemented')) {
      return '当前平台尚未支持心率采集，请使用 Android 设备连接心率带。';
    }
    return '操作失败，请确认蓝牙已开启、心率带处于可连接状态后重试。';
  }

  static String roomError(Object error) {
    final text = '$error';
    if (text.contains('Address is empty')) {
      return '请输入中继地址，或填写房间短码后重试。';
    }
    if (text.contains('Expected ws://') || text.contains('ws:// or wss://')) {
      return '中继地址格式不正确，请输入“主机地址:端口”，例如 192.168.1.10:8765。';
    }
    return '无法加入房间，请检查设备是否在同一局域网、房间短码和中继地址是否正确，然后重试。';
  }

  static String exportError(Object error) => '日志导出失败，请确认系统分享功能可用后重试。';
}
