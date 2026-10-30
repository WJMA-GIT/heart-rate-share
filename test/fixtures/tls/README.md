# 测试专用自签证书

只用于 `test/room_tls_transport_test.dart` 里"wss 必须真的走 TLS"的回归测试。

- `localhost-cert.pem` / `localhost-key.pem`：自签，`CN=localhost`，
  SAN 含 `DNS:localhost, IP:127.0.0.1`，10 年有效，**只在本机回环使用**。
- 私钥是公开的、一次性的，不对应任何真实服务；不要复用到任何环境。
- 生成方式：

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout localhost-key.pem -out localhost-cert.pem -days 3650 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

证书 DER 的 SHA-256（测试里用作钉扎指纹）：
`4472afd6779e699c61b592e496b6b2d9d3c41b2e7c542bc5606167fa58ca04e9`
