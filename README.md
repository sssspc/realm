## realm
## 脚本界面预览：

```
欢迎使用realm一键转发脚本
=================
1. 部署环境
2. 添加转发
3. 添加端口段转发
4. 删除转发
5. 启动服务
6. 停止服务
7. 重启服务
8. 检测更新
9. 一键卸载
10. 更新脚本
0. 退出脚本
=================
realm 状态：已安装
realm 转发状态：启用
```
## 一键脚本：
```
curl -L https://github.com/sssspc/realm/releases/download/v1.0/realm.sh -o realm.sh && chmod +x realm.sh &&  ./realm.sh
```
或
```
curl -L https://raw.githubusercontent.com/sssspc/realm/refs/heads/main/realm.sh -o realm.sh && chmod +x realm.sh &&  ./realm.sh
```
## 默认配置文件（脚本在首次部署环境时会自动添加）
```
[network]
no_tcp = false #是否关闭tcp转发
use_udp = true #是否开启udp转发
zero_copy = true
fast_open = true
tcp_timeout = 300
udp_timeout = 30
send_proxy = false
send_proxy_version = 2
accept_proxy = false
accept_proxy_timeout = 5

#参考模板
# [[endpoints]]
# listen = "0.0.0.0:本地端口"
# remote = "目标机ip:目标端口"

[[endpoints]]
listen = "0.0.0.0:1234"
remote = "1.1.1.1:5678"
```
## 如需其他更多配置请参考官方文档： https://github.com/zhboner/realm
