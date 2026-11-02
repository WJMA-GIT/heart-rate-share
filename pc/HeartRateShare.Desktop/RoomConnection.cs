using System.Net.WebSockets;
using System.Text;

namespace HeartRateShare.Desktop;

/// 一条 v1 WebSocket 连接：hello → snapshot/memberDelta/heartRate 进成员表，3 秒 ping。
/// 局域网（ws://手机:8770/ws?room=）与云端（wss://heart.mawj.asia:10086/ws?room=）共用。
public sealed class RoomConnection : IAsyncDisposable
{
    private readonly MemberTable _table = new();
    private readonly string _memberId = $"win-{Guid.NewGuid():N}"[..12];
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _cts;

    public event Action<IReadOnlyList<MemberRow>>? MembersChanged;
    public event Action<string>? Status;
    public event Action<string>? Failed;

    public string MemberId => _memberId;
    public bool Connected => _socket?.State == WebSocketState.Open;

    public static Uri BuildUri(string host, int port, bool secure, string room) =>
        new($"{(secure ? "wss" : "ws")}://{host}:{port}{Protocol.WsPath}?room={Uri.EscapeDataString(room)}");

    public async Task ConnectAsync(Uri uri, string displayName)
    {
        await CloseAsync();
        _cts = new CancellationTokenSource();
        var socket = new ClientWebSocket();
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);
        try
        {
            await socket.ConnectAsync(uri, _cts.Token);
        }
        catch (Exception error)
        {
            Failed?.Invoke($"连不上 {uri.Host}:{uri.Port}（{error.Message}）");
            return;
        }
        _socket = socket;
        Status?.Invoke("已连接");
        await SendAsync(Protocol.Envelope("hello", ("memberId", _memberId), ("displayName", displayName)));
        _ = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        _ = Task.Run(() => PingLoopAsync(_cts.Token));
    }

    private async Task SendAsync(string payload)
    {
        var socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open) return;
        var bytes = Encoding.UTF8.GetBytes(payload);
        try
        {
            await socket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch (Exception)
        {
            // 发不出去就是链路死了，交给接收循环收尾
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken token)
    {
        var buffer = new byte[8 * 1024];
        var builder = new StringBuilder();
        try
        {
            while (!token.IsCancellationRequested && _socket is { State: WebSocketState.Open } socket)
            {
                var result = await socket.ReceiveAsync(buffer, token);
                if (result.MessageType == WebSocketMessageType.Close) break;
                builder.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                if (!result.EndOfMessage) continue;
                var json = builder.ToString();
                builder.Clear();
                MembersChanged?.Invoke(_table.Apply(json, DateTime.UtcNow));
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception error)
        {
            Failed?.Invoke($"连接中断：{error.Message}");
        }
        Status?.Invoke("已断开");
        MembersChanged?.Invoke([]);
    }

    private async Task PingLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && Connected)
        {
            await SendAsync(Protocol.Envelope("ping", ("displayName", "Windows")));
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(3), token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    public async Task CloseAsync()
    {
        _cts?.Cancel();
        var socket = _socket;
        _socket = null;
        if (socket is null) return;
        try
        {
            if (socket.State == WebSocketState.Open)
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
            }
        }
        catch (Exception)
        {
            // 关不掉就直接丢
        }
        socket.Dispose();
        _table.Clear();
    }

    public ValueTask DisposeAsync() => new(CloseAsync());
}
