## realm
参考自https://github.com/wcwq98/realm，https://github.com/zeroornull/doc/blob/master/docs/MJJ/Realm%E7%AB%AF%E5%8F%A3%E8%BD%AC%E5%8F%91%E5%B7%A5%E5%85%B7%E5%AE%89%E8%A3%85%E6%95%99%E7%A8%8B.md
## 脚本界面预览：

```
欢迎使用realm一键转发脚本
=================
1. 部署环境
2. 添加转发
3. 添加端口段转发
4. 查看您添加的现有realm配置
5. 删除转发
6. 启动服务
7. 停止服务
8. 重启服务
9. realm服务检测更新
10. 一键卸载
11. 更新脚本
0. 退出脚本
=================
realm 状态：已安装
realm 转发状态：启用
```
## 一键脚本：
```
curl -L https://github.com/sssspc/realm/releases/download/v1.4/realm.sh -o realm.sh && chmod +x realm.sh &&  ./realm.sh
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
listen = "0.0.0.0:15678"
remote = "1.1.1.1:443"
```
## 如需其他更多配置请参考官方文档： https://github.com/zhboner/realm
