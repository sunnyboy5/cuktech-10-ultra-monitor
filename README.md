# CuktechMonitor — 酷态科 10 Ultra 充电器菜单栏功率监控

macOS 原生应用（Swift + SwiftUI + CoreBluetooth），通过 Mac 自带蓝牙 BLE 直连 **酷态科 10 Ultra（CUKTECH 10 Ultra）氮化镓充电器**，在菜单栏实时显示总功率与各端口输出。不经过米家云、不联网、不上传任何数据。

## 功能

- 菜单栏常驻（MenuBarExtra），标签实时显示当前总功率
- 弹出面板：总功率大数字 + C1 / C2 / C3 / USB-A 四端口电压电流
- 刷新率可选：0.5 / 1 / 2 / 3 / 5 秒
- 断线自动重连（指数退避）；多台 BLE 设备时逐台识别出充电器
- Token 可在设置中修改，配置保存在本地

包含两个独立 App：

| App | 用途 |
|---|---|
| `CuktechMonitor.app` | 菜单栏监控版，日常使用 |
| `CuktechDebugger.app` | BLE 调试版，可看广播数据、认证步骤、加解密日志 |

## 协议实现

协议细节参考开源项目 [kairui1108/cuktech-ble-server](https://github.com/kairui1108/cuktech-ble-server)（Python 实现），本项目将其完整移植到 Swift：

- 小米 MiOT BLE 服务（`0xFE95`），6 个 Characteristic（设备信息 / 认证控制 / 认证数据 / 命令收发 / 固件版本）
- MiOT 登录认证：双方交换 16 字节随机数，HKDF-SHA256 派生 64 字节会话密钥，HMAC-SHA256 双向验证 + challenge 应答
- AES-CCM 加密命令通道（tag 4 字节，计数器 it 回绕跟踪）
- MiOT TLV 命令帧 + GATT 内联帧 / 多帧 ACK 流控
- 端口解码：`siid=2, piid=1..4` 对应 C1/C2/C3/USB-A，明文末 4 字节 `[status][code][电流raw][电压raw]`，均 ÷10 得 A/V；总功率 = 四口之和

## 获取 Token

1. 在米家 App 中绑定充电器
2. 用 [Xiaomi-cloud-tokens-extractor](https://github.com/Puyodead1/xiaomi-cloud-tokens-extractor) 从你的小米账号提取 12 字节 token（24 位十六进制）
3. 在 App 设置（⚙）中填入即可

Token 只存本机，App 本身不联网。

## 从源码构建

要求 macOS 13+，只需安装 Xcode Command Line Tools（`xcode-select --install`），无需完整 Xcode：

```bash
git clone https://github.com/sunnyboy5/cuktech-10-ultra-monitor.git
cd cuktech-10-ultra-monitor
bash tools/build_app.sh monitor     # 菜单栏监控版
bash tools/build_app.sh debugger    # BLE 调试版
```

产物在 `Build/` 目录。图标由 [tools/make_icon.sh](tools/make_icon.sh) 生成。

也可直接从 [Releases](../../releases) 下载打包好的 DMG。首次打开请在 App 上右键 →「打开」以绕过 Gatekeeper，并在系统弹窗中允许蓝牙权限。

## 已知限制

- 充电器空闲时不会主动推送，实时刷新约 1.7 秒/轮（BLE GATT 往返的物理下限）
- BLE 协议未提供温度通道（探测过 piid 22–35 均无响应）
- 需要在蓝牙范围内使用

## 免责声明

仅供个人学习研究使用，与 CUKTECH / 小米官方无关。请勿高频轮询，以免影响设备正常工作。
