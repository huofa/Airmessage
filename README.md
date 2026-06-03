# Airmessage

Version: `0.1.3`

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

## 打包成拖动安装 `.dmg`

```bash
chmod +x build_dmg.sh
./build_dmg.sh
```

生成的 `Airmessage-0.1.3.dmg` 打开后，把 `Airmessage.app` 拖到 `Applications` 即可。

## 功能

- 菜单栏常驻，不占 Dock。
- 默认每 45 分钟提醒一次“该喝水啦”。
- 支持 15/30/45/60/90/120 分钟快速间隔。
- 支持自定义提醒文字和提醒间隔。
- 支持自定义每次提醒的飞行次数和飞行时长。
- 支持暂停、继续、立刻试飞。
- 支持 `Command + 0` 快捷试飞。
- 飞机飞过时可用鼠标左键拖动位置，松开后继续向右飞行。
- 白色飞机牵引湖蓝色飘旗提醒，从桌面层优雅掠过。
- 内置多种 fly-by 音效，可在菜单栏开关和选择。

## 自定义音效

音效文件放在：

```text
Sources/Airmessage/Resources/
```

当前内置文件：

- `flyby_long.mp3`：长空气声，约 11 秒，默认使用。
- `flyby_jet.mp3`：强劲喷气声，约 28 秒。
- `flyby.wav`：柔和备用音效。

打包时 `build_app.sh` 会复制资源到 `.app/Contents/Resources/`。
