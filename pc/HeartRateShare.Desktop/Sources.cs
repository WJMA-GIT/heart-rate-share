using System.Net;
using System.Net.Sockets;
using System.Text;

namespace HeartRateShare.Desktop;

/// 三条通路对 UI 是同一个东西：给我成员心率，别管我从哪来。
public interface IHeartRateSource : IAsyncDisposable
{
    string Transport { get; }
    bool Connected { get; }
    event Action<IReadOnlyList<MemberRow>>? MembersChanged;
    event Action<string>? Status;
    event Action<string>? Failed;
    Task DisconnectAsync();
}

/// 局域网：UDP 8771 收手机广播，连上后走 ws://手机:8770/ws?room=<room>（v1 协议）。
public sealed class LanSource : IHeartRateSource
{
    private readonly RoomConnection _connection = new();
    private readonly List<Beacon> _peers = [];
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;

    public string Transport => "局域网";
    public bool Connected => _connection.Connected;
    public IReadOnlyList<Beacon> Peers => _peers.ToList();
    public event Action<IReadOnlyList<MemberRow>>? MembersChanged;
    public event Action<string>? Status;
    public event Action<string>? Failed;
    public event Action? PeersChanged;

    public LanSource()
    {
        _connection.MembersChanged += rows => MembersChanged?.Invoke(rows);
        _connection.Status += text => Status?.Invoke(text);
        _connection.Failed += text => Failed?.Invoke(text);
    }

    public void StartDiscovery()
    {
        if (_udp is not null) return;
        _cts = new CancellationTokenSource();
        try
        {
            var udp = new UdpClient();
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, Protocol.BeaconPort));
            _udp = udp;
        }
        catch (Exception error)
        {
            Failed?.Invoke($"无法监听 {Protocol.BeaconPort} 端口：{error.Message}");
            return;
        }
        _ = Task.Run(() => DiscoveryLoopAsync(_cts.Token));
    }

    private async Task DiscoveryLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _udp is not null)
        {
            UdpReceiveResult result;
            try
            {
                result = await _udp.ReceiveAsync(token);
            }
            catch (Exception)
            {
                return;
            }
            var beacon = BeaconParser.TryParse(result.RemoteEndPoint.Address.ToString(),
                Encoding.UTF8.GetString(result.Buffer));
            if (beacon is null) continue;
            var index = _peers.FindIndex(peer => peer.Host == beacon.Host && peer.Port == beacon.Port);
            if (index >= 0) _peers[index] = beacon; else _peers.Add(beacon);
            PeersChanged?.Invoke();
        }
    }

    public async Task ConnectAsync(Beacon peer, string displayName)
    {
        var uri = RoomConnection.BuildUri(peer.Host, peer.Port, false, peer.Room);
        await _connection.ConnectAsync(uri, displayName);
    }

    public async Task ConnectManualAsync(string hostPort, string displayName)
    {
        var parts = hostPort.Split(':', 2);
        var host = parts[0].Trim();
        var port = parts.Length > 1 && int.TryParse(parts[1], out var parsed) ? parsed : Protocol.LanPort;
        if (string.IsNullOrWhiteSpace(host) || port is < 1 or > 65535)
        {
            Failed?.Invoke("格式：IP 或 IP:端口（端口 1-65535）");
            return;
        }
        await _connection.ConnectAsync(
            RoomConnection.BuildUri(host, port, false, ""), displayName);
    }

    public async Task DisconnectAsync()
    {
        await _connection.CloseAsync();
        _cts?.Cancel();
        _udp?.Dispose();
        _udp = null;
    }

    public ValueTask DisposeAsync() => new(DisconnectAsync());
}

/// 云端：wss://heart.mawj.asia:10086/ws?room=<code>（可换自定义服务器，证书校验不放松）。
public sealed class CloudSource : IHeartRateSource
{
    private readonly RoomConnection _connection = new();

    public string Transport => "云端";
    public bool Connected => _connection.Connected;
    public event Action<IReadOnlyList<MemberRow>>? MembersChanged;
    public event Action<string>? Status;
    public event Action<string>? Failed;

    public CloudSource()
    {
        _connection.MembersChanged += rows => MembersChanged?.Invoke(rows);
        _connection.Status += text => Status?.Invoke(text);
        _connection.Failed += text => Failed?.Invoke(text);
    }

    /// server 传 "wss://host:port" 或裸主机名；房间号先按服务端规则校验。
    public async Task ConnectAsync(string server, string room, string displayName)
    {
        var code = Protocol.NormalizeRoomCode(room);
        if (code is null)
        {
            Failed?.Invoke("房间号只能用字母/数字/下划线/短横线，1–64 位");
            return;
        }
        if (!TryParseServer(server, out var host, out var port, out var secure, out var reason))
        {
            Failed?.Invoke(reason);
            return;
        }
        await _connection.ConnectAsync(RoomConnection.BuildUri(host, port, secure, code), displayName);
    }

    public static bool TryParseServer(string raw, out string host, out int port, out bool secure,
        out string reason)
    {
        host = string.Empty;
        port = 10086;
        secure = true;
        reason = string.Empty;
        var text = (raw ?? string.Empty).Trim();
        if (text.Length == 0) text = Protocol.OfficialServer;
        if (!text.Contains("://")) text = "wss://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri))
        {
            reason = "服务器地址解析失败（示例：wss://heart.mawj.asia:10086）";
            return false;
        }
        if (uri.Scheme == "ws")
        {
            reason = "云端必须用 wss://（不放松证书校验）";
            return false;
        }
        if (uri.Scheme != "wss")
        {
            reason = "只支持 wss://";
            return false;
        }
        host = uri.Host;
        port = uri.IsDefaultPort ? 10086 : uri.Port;
        secure = true;
        return true;
    }

    public Task DisconnectAsync() => _connection.CloseAsync();
    public ValueTask DisposeAsync() => new(DisconnectAsync());
}
