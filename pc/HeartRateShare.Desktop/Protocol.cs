using System.Text.Json;
using System.Text.RegularExpressions;

namespace HeartRateShare.Desktop;

/// v1 协议（与手机端/relay 完全一致，不新增字段、不放宽校验）。
public static class Protocol
{
    public const int Version = 1;
    public const string WsPath = "/ws";
    public const string OfficialServer = "wss://heart.mawj.asia:10086";
    public const int LanPort = 8770;
    public const int BeaconPort = 8771;
    public const int MaxMembers = 20;
    public static readonly TimeSpan OfflineAfter = TimeSpan.FromSeconds(5);

    private static readonly Regex RoomPattern = new("^[A-Za-z0-9_-]{1,64}$", RegexOptions.Compiled);
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public static bool IsValidRoomCode(string? value) =>
        !string.IsNullOrWhiteSpace(value) && RoomPattern.IsMatch(value.Trim());

    public static string? NormalizeRoomCode(string? value) =>
        IsValidRoomCode(value) ? value!.Trim() : null;

    public static string GenerateRoomCode(string alphabet = Alphabet, int length = 6)
    {
        var chars = new char[length];
        for (var i = 0; i < length; i++) chars[i] = alphabet[Random.Shared.Next(alphabet.Length)];
        return new string(chars);
    }

    /// 组一条 v1 消息：{v, type, ...data}。
    public static string Envelope(string type, params (string Key, object? Value)[] fields)
    {
        var map = new Dictionary<string, object?> { ["v"] = Version, ["type"] = type };
        foreach (var (key, value) in fields) map[key] = value;
        return JsonSerializer.Serialize(map);
    }

    /// 解一条 v1 消息；版本/类型不认识就返回 false（调用方只记日志、不崩）。
    public static bool TryParseEnvelope(string json, out string type, out JsonElement root)
    {
        type = string.Empty;
        root = default;
        try
        {
            using var document = JsonDocument.Parse(json);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return false;
        }
        if (root.ValueKind != JsonValueKind.Object) return false;
        if (!root.TryGetProperty("v", out var version) || version.GetInt32() != Version) return false;
        if (!root.TryGetProperty("type", out var typeElement)) return false;
        type = typeElement.GetString() ?? string.Empty;
        return type.Length > 0;
    }
}

/// 0x2A37 心率测量：flags 决定 uint8/uint16，以及后面是否跟 RR。
public static class HeartRateMeasurement
{
    public static bool TryParse(ReadOnlySpan<byte> data, out int bpm, out List<int> rrMs)
    {
        bpm = 0;
        rrMs = [];
        if (data.Length < 2) return false;
        var flags = data[0];
        var isUint16 = (flags & 0x01) != 0;
        var hasRr = (flags & 0x10) != 0;
        var offset = 1;
        if (isUint16)
        {
            if (data.Length < 3) return false;
            bpm = data[1] | (data[2] << 8);
            offset = 3;
        }
        else
        {
            bpm = data[1];
            offset = 2;   // uint8 时 RR 从第 3 个字节开始
        }
        if (bpm is <= 0 or > 250) return false;   // 物理上不可能，按坏帧丢掉
        if (hasRr)
        {
            while (offset + 1 < data.Length)
            {
                var raw = data[offset] | (data[offset + 1] << 8);
                rrMs.Add(raw);
                offset += 2;
            }
            rrMs.RemoveAll(value => value <= 0 || value > 4000);
        }
        return true;
    }
}

/// UDP 8771 广播：{"app":"heart-rate-share","room":..,"port":..,"name":..,"platform":..,"members":..}
public sealed record Beacon(string Host, string Room, int Port, string Name, string Platform, int Members);

public static class BeaconParser
{
    public static Beacon? TryParse(string host, string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("app", out var app) || app.GetString() != "heart-rate-share") return null;
            if (!root.TryGetProperty("port", out var port) || port.GetInt32() <= 0) return null;
            var room = root.TryGetProperty("room", out var roomElement) ? roomElement.GetString() ?? "" : "";
            var name = root.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? host : host;
            var platform = root.TryGetProperty("platform", out var pf) ? pf.GetString() ?? "android" : "android";
            var members = root.TryGetProperty("members", out var mc) ? mc.GetInt32() : 0;
            return new Beacon(host, room, port.GetInt32(), name, platform, members);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// UI 只看这个：谁、多少、在线不在线（不管数据来自蓝牙/局域网/云端）。
public sealed record MemberRow(string Id, string Name, int Bpm, bool Online);

/// 房间成员表：snapshot 全量、memberDelta 增量，5 秒没更新就是离线。
public sealed class MemberTable
{
    private readonly Dictionary<string, (string Name, int Bpm, DateTime MeasuredAt)> _rows = [];

    public IReadOnlyList<MemberRow> Apply(string json, DateTime now)
    {
        if (!Protocol.TryParseEnvelope(json, out var type, out var root)) return Snapshot(now);
        switch (type)
        {
            case "snapshot":
                if (root.TryGetProperty("members", out var members) && members.ValueKind == JsonValueKind.Array)
                {
                    _rows.Clear();
                    foreach (var member in members.EnumerateArray()) Upsert(member);
                }
                break;
            case "memberDelta":
                if (root.TryGetProperty("member", out var delta)) Upsert(delta);
                break;
            case "heartRate":
                Upsert(root);
                break;
        }
        return Snapshot(now);
    }

    private void Upsert(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) return;
        if (!element.TryGetProperty("memberId", out var idElement)) return;
        var id = idElement.GetString();
        if (string.IsNullOrEmpty(id)) return;
        var name = element.TryGetProperty("displayName", out var nameElement)
            ? nameElement.GetString() ?? id
            : id;
        var bpm = element.TryGetProperty("bpm", out var bpmElement) ? bpmElement.GetInt32() : 0;
        _rows[id] = (name, bpm, DateTime.UtcNow);
    }

    public IReadOnlyList<MemberRow> Snapshot(DateTime now) =>
        _rows.Select(pair => new MemberRow(
                pair.Key,
                pair.Value.Name,
                pair.Value.Bpm,
                now - pair.Value.MeasuredAt <= Protocol.OfflineAfter))
            .OrderByDescending(row => row.Online)
            .ThenBy(row => row.Name, StringComparer.Ordinal)
            .ToList();

    public void Clear() => _rows.Clear();
}
