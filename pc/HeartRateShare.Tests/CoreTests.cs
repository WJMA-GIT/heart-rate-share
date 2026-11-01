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

/// 端到端：本地 TCP + 手写 WebSocket 握手（不用 HttpListener，避免 CI 上的 URL ACL）。
public class RoomConnectionTests
{
    [Fact]
    public async Task ConnectsReceivesSnapshotAndDisconnects()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;

        var serverTask = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync();
            var stream = client.GetStream();
            var request = await ReadHeadersAsync(stream);
            var key = request.Split("\r\n")
                .First(line => line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase))
                .Split(':', 2)[1].Trim();
            var accept = Convert.ToBase64String(
                System.Security.Cryptography.SHA1.HashData(
                    Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            var handshake = Encoding.ASCII.GetBytes(
                "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
                $"Sec-WebSocket-Accept: {accept}\r\n\r\n");
            await stream.WriteAsync(handshake);
            await stream.FlushAsync();

            // 客户端会先发 hello：读一帧（不校验内容，只看握手通了）
            _ = await ReadFrameAsync(stream);

            var snapshot = Encoding.UTF8.GetBytes("""
            {"v":1,"type":"snapshot","members":[{"memberId":"s1","displayName":"服务端成员","bpm":77}]}
            """);
            await WriteTextFrameAsync(stream, snapshot);
            await Task.Delay(200);
        });

        var connection = new RoomConnection();
        var rows = new List<MemberRow>();
        connection.MembersChanged += snapshot => rows = snapshot.ToList();
        await connection.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/ws?room=TEST01"), "Windows");
        for (var i = 0; i < 40 && rows.Count == 0; i++) await Task.Delay(50);

        Assert.Single(rows);
        Assert.Equal("服务端成员", rows[0].Name);
        Assert.Equal(77, rows[0].Bpm);

        await connection.CloseAsync();
        listener.Stop();
        await serverTask;
    }

    private static async Task<string> ReadHeadersAsync(NetworkStream stream)
    {
        var buffer = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            var read = await stream.ReadAsync(one);
            if (read == 0) break;
            buffer.Add(one[0]);
            if (buffer.Count >= 4 &&
                buffer[^4] == (byte)'\r' && buffer[^3] == (byte)'\n' &&
                buffer[^2] == (byte)'\r' && buffer[^1] == (byte)'\n') break;
        }
        return Encoding.ASCII.GetString(buffer.ToArray());
    }

    private static async Task<byte[]> ReadFrameAsync(NetworkStream stream)
    {
        var header = new byte[2];
        await stream.ReadExactlyAsync(header);
        var length = header[1] & 0x7F;
        if (length == 126)
        {
            var extended = new byte[2];
            await stream.ReadExactlyAsync(extended);
            length = (extended[0] << 8) | extended[1];
        }
        var mask = new byte[4];
        if ((header[1] & 0x80) != 0) await stream.ReadExactlyAsync(mask);
        var payload = new byte[length];
        await stream.ReadExactlyAsync(payload);
        for (var i = 0; i < payload.Length; i++) payload[i] ^= mask[i % 4];
        return payload;
    }

    private static async Task WriteTextFrameAsync(NetworkStream stream, byte[] payload)
    {
        var frame = new List<byte> { 0x81 };
        if (payload.Length < 126)
        {
            frame.Add((byte)payload.Length);
        }
        else
        {
            frame.Add(126);
            frame.Add((byte)(payload.Length >> 8));
            frame.Add((byte)(payload.Length & 0xFF));
        }
        frame.AddRange(payload);
        await stream.WriteAsync(frame.ToArray());
        await stream.FlushAsync();
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
