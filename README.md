# AnyTLS-Manager

[![Top Language](https://img.shields.io/github/languages/top/Kismet0123/AnyTLS-Manager.svg)]([https://github.com/Kismet0123/ShadowTLS-Manager](https://github.com/Kismet0123/AnyTLS-Manager))

AnyTLS 管理脚本，支持一键安装、升级和卸载

>  AnyTLS是一个试图专注于缓解 "TLS in TLS" 问题的 TLS 代理协议（具有灵活的分包和填充策略、连接复用，降低代理延迟、简洁的配置的特点）

> [!IMPORTANT]
> AnyTLS官方二进制使用自签证书，若需要使用自定义域名证书建议使用Sing-Box

---

## 快速开始📃

**一键部署命令**

```bash
wget -O AnyTLS_Manager.sh --no-check-certificate https://raw.githubusercontent.com/Kismet0123/AnyTLS-Manager/refs/heads/main/AnyTLS_Manager.sh && chmod +x AnyTLS_Manager.sh && ./AnyTLS_Manager.sh
```

**查看日志**

```
journalctl -u anytls
```

**删除脚本**

```
rm AnyTLS_Manager.sh
```

## 客户端配置参考🖥️

### Mihomo 配置参考示例(自mihomo 1.19.3 起)

```
proxies:
- name: anytls
  type: anytls
  server: 1.2.3.4
  port: 443
  password: "<your password>"
  client-fingerprint: chrome
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  sni: "example.com"
  alpn:
    - h2
    - http/1.1
  skip-cert-verify: true
```

### Singbox配置参考示例(自 sing-box 1.12.0 起)

```
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "127.0.0.1",
  "server_port": 1080,
  "password": "8JCsPssfgS8tiRwiMlhARg==",
  "idle_session_check_interval": "30s",
  "idle_session_timeout": "30s",
  "min_idle_session": 5,
  "tls": {},

  ... // 拨号字段
}
```

# 参考资料📚

## [AnyTLS原仓库](https://github.com/anytls/anytls-go)

## [AnyTLS官方FAQ](https://github.com/anytls/anytls-go/blob/main/docs/faq.md)

## [AnyTLS协议说明](https://github.com/anytls/anytls-go/blob/main/docs/protocol.md)
