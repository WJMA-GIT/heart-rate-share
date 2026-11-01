using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using HeartRateShare.Desktop;
using Xunit;

namespace HeartRateShare.Tests;

public class RoomCodeTests
{
    [Theory]
    [InlineData("ABC123", true)]
    [InlineData("a_b-c9", true)]
    [InlineData("   ABC123  ", true)]     // 前后空白会被 trim
    [InlineData("", false)]
    [InlineData("   ", false)]
    [InlineData("坏房间", false)]
    [InlineData("has space", false)]
    [InlineData("a.b", false)]
    public void Validates(string code, bool expected) =>
        Assert.Equal(expected, Protocol.IsValidRoomCode(code));

    [Fact]
    public void RejectsTooLong()
    {
        Assert.True(Protocol.IsValidRoomCode(new string('a', 64)));
        Assert.False(Protocol.IsValidRoomCode(new string('a', 65)));
    }

    [Fact]
    public void GenerateIsAlwaysValidAndReadable()
    {
        for (var i = 0; i < 50; i++)
        {
            var code = Protocol.GenerateRoomCode();
            Assert.True(Protocol.IsValidRoomCode(code));
            Assert.Equal(6, code.Length);
            Assert.DoesNotContain('0', code);
            Assert.DoesNotContain('O', code);
            Assert.DoesNotContain('1', code);
            Assert.DoesNotContain('I', code);
        }
    }
}

public class HeartRateFlagsTests
{
    [Fact]
    public void Uint8WithoutRr()
    {
        Assert.True(HeartRateMeasurement.TryParse(new byte[] { 0x00, 72 }, out var bpm, out var rr));
        Assert.Equal(72, bpm);
        Assert.Empty(rr);
    }

    [Fact]
    public void Uint16WithRr()
    {
        // flags: bit0=uint16, bit4=RR；bpm=180(0x00B4)，两个 RR=300/400ms
        var data = new byte[] { 0x11, 0xB4, 0x00, 0x2C, 0x01, 0x90, 0x01 };
        Assert.True(HeartRateMeasurement.TryParse(data, out var bpm, out var rr));
        Assert.Equal(180, bpm);
        Assert.Equal(new List<int> { 300, 400 }, rr);
    }

    [Fact]
    public void RejectsImpossibleBpm()
    {
        Assert.False(HeartRateMeasurement.TryParse(new byte[] { 0x00, 0 }, out _, out _));
        Assert.False(HeartRateMeasurement.TryParse(new byte[] { 0x00, 255 }, out _, out _));
        Assert.False(HeartRateMeasurement.TryParse(new byte[] { 0x00 }, out _, out _));
    }

    [Fact]
    public void DropsBogusRr()
    {
        var data = new byte[] { 0x10, 0x40, 0x00, 0x00, 0xFF, 0xFF };
        Assert.True(HeartRateMeasurement.TryParse(data, out var bpm, out var rr));
        Assert.Equal(64, bpm);
        Assert.Empty(rr);   // 0 和 65535 都不是有效 RR
    }
}

public class BeaconTests
{
    [Fact]
    public void ParsesRealBeacon()
    {
        var json = """{"app":"heart-rate-share","room":"ABC123","port":8770,"name":"小明的手机","platform":"android","members":3}""";
        var beacon = BeaconParser.TryParse("192.168.1.20", json);
        Assert.NotNull(beacon);
        Assert.Equal("192.168.1.20", beacon!.Host);
        Assert.Equal("ABC123", beacon.Room);
        Assert.Equal(8770, beacon.Port);
        Assert.Equal("小明的手机", beacon.Name);
        Assert.Equal(3, beacon.Members);
    }

    [Theory]
    [InlineData("""{"app":"other","port":8770}""")]
    [InlineData("""{"app":"heart-rate-share","port":0}""")]
    [InlineData("not json")]
    public void RejectsGarbage(string json) =>
        Assert.Null(BeaconParser.TryParse("10.0.0.1", json));
}

public class EnvelopeTests
{
    [Fact]
    public void RoundTrips()
    {
        var json = Protocol.Envelope("hello", ("memberId", "win-1"), ("displayName", "Windows"));
        Assert.True(Protocol.TryParseEnvelope(json, out var type, out var root));
        Assert.Equal("hello", type);
        Assert.Equal(1, root.GetProperty("v").GetInt32());
        Assert.Equal("win-1", root.GetProperty("memberId").GetString());
    }

    [Fact]
    public void RejectsWrongVersion()
        => Assert.False(Protocol.TryParseEnvelope("""{"v":2,"type":"hello"}""", out _, out _));

    [Fact]
    public void RejectsUnknownShape()
    {
        Assert.False(Protocol.TryParseEnvelope("[]", out _, out _));
        Assert.False(Protocol.TryParseEnvelope("""{"v":1}""", out _, out _));
        Assert.False(Protocol.TryParseEnvelope("nope", out _, out _));
    }
}

public class MemberTableTests
{
    [Fact]
    public void AppliesSnapshotAndGoesOfflineAfterFiveSeconds()
    {
        var table = new MemberTable();
        var now = DateTime.UtcNow;
        var snapshot = """
        {"v":1,"type":"snapshot","members":[
          {"memberId":"a","displayName":"小明","bpm":72},
          {"memberId":"b","displayName":"小红","bpm":68}]}
        """;
        var rows = table.Apply(snapshot, now);
        Assert.Equal(2, rows.Count);
        Assert.All(rows, row => Assert.True(row.Online));

        var later = table.Snapshot(now + TimeSpan.FromSeconds(6));
        Assert.All(later, row => Assert.False(row.Online));
    }

    [Fact]
    public void AppliesDelta()
    {
        var table = new MemberTable();
        var now = DateTime.UtcNow;
        table.Apply("""{"v":1,"type":"snapshot","members":[]}""", now);
        var rows = table.Apply("""{"v":1,"type":"memberDelta","member":{"memberId":"c","displayName":"阿强","bpm":90}}""", now);
        Assert.Single(rows);
        Assert.Equal(90, rows[0].Bpm);
    }
}

/// 端到端：本地 HttpListener 起一个 WS 服务，RoomConnection 连上去收 snapshot。
public class RoomConnectionTests
{
    [Fact]
    public async Task ConnectsReceivesSnapshotAndDisconnects()
    {
        var listener = new HttpListener();
        var port = FreePort();
        listener.Prefixes.Add($"http://localhost:{port}/");
        listener.Start();
        var serverTask = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            var socketContext = await context.AcceptWebSocketAsync(null);
            var socket = socketContext.WebSocket;
            var buffer = new byte[4096];
            var received = await socket.ReceiveAsync(buffer, CancellationToken.None);
            var hello = Encoding.UTF8.GetString(buffer, 0, received.Count);
            Assert.Contains("\"hello\"", hello);

            var snapshot = Encoding.UTF8.GetBytes("""
            {"v":1,"type":"snapshot","members":[{"memberId":"s1","displayName":"服务端成员","bpm":77}]}
            """);
            await socket.SendAsync(snapshot, WebSocketMessageType.Text, true, CancellationToken.None);
            await Task.Delay(300);
            await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None);
        });

        var connection = new RoomConnection();
        var rows = new List<MemberRow>();
        connection.MembersChanged += snapshot => rows = snapshot.ToList();
        await connection.ConnectAsync(
            new Uri($"ws://localhost:{port}/ws?room=TEST01"), "Windows");
        for (var i = 0; i < 30 && rows.Count == 0; i++) await Task.Delay(50);

        Assert.Single(rows);
        Assert.Equal("服务端成员", rows[0].Name);
        Assert.Equal(77, rows[0].Bpm);

        await connection.CloseAsync();
        listener.Stop();
        await serverTask;
    }

    private static int FreePort()
    {
        var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var port = ((IPEndPoint)udp.Client.LocalEndPoint!).Port;
        udp.Dispose();
        return port;
    }
}

public class LanDiscoveryTests
{
    [Fact]
    public async Task SeesBeaconOn8771()
    {
        var source = new LanSource();
        var seen = new List<Beacon>();
        source.PeersChanged += () => seen = source.Peers.ToList();
        source.StartDiscovery();
        await Task.Delay(120);

        using var sender = new UdpClient();
        var payload = Encoding.UTF8.GetBytes("""
        {"app":"heart-rate-share","room":"LAN123","port":8770,"name":"测试手机","platform":"android","members":2}
        """);
        await sender.SendAsync(payload, new IPEndPoint(IPAddress.Loopback, Protocol.BeaconPort));

        for (var i = 0; i < 30 && seen.Count == 0; i++) await Task.Delay(50);
        Assert.Single(seen);
        Assert.Equal("LAN123", seen[0].Room);
        await source.DisposeAsync();
    }
}
