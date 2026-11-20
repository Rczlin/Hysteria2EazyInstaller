## 简单的说一下
快速安装 Hysteria 2，适用于个人自用的 **Debian 11 / 12 / 13** VPS（仅支持 Debian）。

结束后输出分享链接、二维码、YAML/JSON 客户端配置和 Clash 单行节点，可以扫码，也可以复制链接从剪贴板导入。

推荐使用 [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases)（手机一般选 `arm64-v8a` 版本）。

## 使用
```
curl -sL https://raw.githubusercontent.com/Rczlin/Hysteria2EazyInstaller/refs/heads/main/Hy2Installer.sh -o Hy2Installer.sh && bash Hy2Installer.sh
```
IPv4
```
curl --ipv4 -sL https://raw.githubusercontent.com/Rczlin/Hysteria2EazyInstaller/refs/heads/main/Hy2Installer.sh -o Hy2Installer.sh && bash Hy2Installer.sh
```
IPv6
```
curl --ipv6 -sL https://raw.githubusercontent.com/Rczlin/Hysteria2EazyInstaller/refs/heads/main/Hy2Installer.sh -o Hy2Installer.sh && bash Hy2Installer.sh
```

## 管理命令
安装完成后可直接使用 `hy2`：

| 命令 | 作用 |
| --- | --- |
| `hy2` | 打开管理菜单 |
| `hy2 diag` | 一键排查，并生成打码后的报告 `/root/hy2-diag-*.txt` |
| `hy2 log` | 实时跟踪服务日志 |
| `hy2 status` | 查看服务状态 |
| `hy2 restart` | 重启服务 |
| `hy2 show` | 显示客户端配置 / 分享链接 / 二维码 |

## 连不上怎么办
先运行 `hy2 diag`。它会检查：服务状态与崩溃重启、证书有效期与私钥匹配、文件权限、UDP 端口监听与占用、端口跳跃转发规则、ufw/nftables/iptables、公网 IP、DNS、时间同步、UDP 缓冲区、伪装站可达性、服务日志里的 ERROR/FATAL，最后用本机 hysteria 客户端**自连一次**验证鉴权、TLS 和服务器出站。

如果自连测试通过但手机仍连不上，问题基本在服务器之外：云厂商安全组没放行 UDP 端口，或本地网络限制 UDP。

## 文件位置
- `/etc/hysteria/config.yaml` 服务端配置（640，root:hysteria）
- `/etc/hysteria/hy2.env` 脚本保存的参数（600）
- `/etc/sysctl.d/99-hysteria.conf` UDP 缓冲区调优
