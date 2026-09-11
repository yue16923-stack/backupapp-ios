## 编译

本仓库通过 GitHub Actions 自动编译出 `.ipa`（无需 Mac）：

1. 本仓库已包含 `.github/workflows/build-ipa.yml`，push 到 main/master 自动触发。
2. 在仓库 Actions 页下载 `BackupApp-ipa` 工件。
3. 用爱思助手「签名安装」（免费 Apple ID，7 天有效，过期重签即可）。

## 手动编译（有 Mac 时）

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project BackupApp.xcodeproj -scheme BackupApp -configuration Release -sdk iphoneos build CODE_SIGNING_ALLOWED=NO
```

## 说明

- 免费签名 7 天过期属 Apple 免费开发者签名的正常限制。
- 数据只发往你在 App 里填写的服务器地址，请确认服务器是你的。
