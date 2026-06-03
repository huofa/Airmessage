# Airmessage

Version: `0.1.0`

一个极简 macOS 菜单栏小工具：到点时从桌面飞过一架小飞机，带一条低频消息提醒。

## 运行

```bash
swift run
```

## 打包成 `.app`

```bash
chmod +x build_app.sh
./build_app.sh
open .build/Airmessage.app
```

## 功能

- 菜单栏常驻，不占 Dock。
- 默认每 45 分钟提醒一次“该喝水啦”。
- 支持 15/30/45/60/90/120 分钟快速间隔。
- 支持自定义提醒文字和提醒间隔。
- 支持暂停、继续、立刻试飞。
- 白色飞机牵引红色飘旗提醒，从桌面层优雅掠过。
- 内置柔和 fly-by 音效，可在菜单栏开关。
