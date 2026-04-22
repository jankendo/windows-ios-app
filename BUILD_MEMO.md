# Resonance Build Memo

このメモは、`Resonance` を **Windows で編集し、GitHub Actions の macOS ランナーで IPA を生成する** ための実務用メモです。

## 現在の出力

- Artifact 名: **`resonance-ipa`**
- IPA ファイル名: **`Resonance.ipa`**

署名素材が有効なら署名付き IPA を試行し、失敗時や未設定時は **unsigned IPA** を生成します。

## 基本構成

1. Windows で SwiftUI ソースを編集
2. `main` に push
3. GitHub Actions が `Config\project.yml` から Xcode プロジェクトを生成
4. iOS Simulator 向け検証ビルド
5. 実機向け IPA 生成
6. Artifact として取得

## 必要なもの

- Git for Windows
- VS Code + Swift 拡張
- GitHub Public repository
- Apple Developer アカウント
- `.p12`
- `.mobileprovision`
- `P12_PASSWORD`
- 実機導入するなら Sideloadly + Apple 公式配布版 iTunes

## 署名素材

GitHub Secrets:

| Secret名 | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `.p12` の Base64 |
| `P12_PASSWORD` | `.p12` のパスワード |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision` の Base64 |
| `TEAM_ID` | 任意。未設定なら profile から取得 |

## Base64 化

```powershell
pwsh -File .\scripts\encode-signing-assets.ps1 `
  -P12Path C:\path\to\Certificates.p12 `
  -ProvisioningProfilePath C:\path\to\profile.mobileprovision
```

## GitHub Secrets の投入

```powershell
pwsh -File .\scripts\publish-github-secrets.ps1 `
  -Repository YOUR_GITHUB_NAME/YOUR_REPOSITORY `
  -P12Password 'YOUR_P12_PASSWORD' `
  -TeamId 2M6M6BW775
```

## GitHub Actions

ワークフロー: `.github\workflows\build-ios.yml`

主な流れ:

1. `xcodegen` をインストール
2. `Config\project.yml` から `MyFirstApp.xcodeproj` を生成
3. Simulator 向け署名なしビルドで検証
4. 署名素材があれば archive/export を試行
5. 失敗時は unsigned IPA をフォールバック生成
6. `Resonance.ipa` を Artifact として保存

## 実機導入

1. Actions 完了後に **`resonance-ipa`** Artifact をダウンロード
2. ZIP を展開して `Resonance.ipa` を取り出す
3. iPhone を USB 接続して Sideloadly を起動
4. `Resonance.ipa` をドラッグ & ドロップ
5. iPhone 側で Apple ID を信頼

## 実行時の権限

- カメラ
- マイク
- 位置情報（地図表示と場所記録）
- モーション / フィットネス（端末姿勢・気圧由来の空間情報）
- 取得可能なら WeatherKit による天気 / 気温（未設定や利用不可時は自動でスキップ）

## WeatherKit メモ

- 現在の project は **WeatherKit entitlement** を含む構成
- Apple Developer 側で WeatherKit capability が利用可能な状態であることが前提
- **Apple Developer > Certificates, Identifiers & Profiles > Identifiers** で、この app の **Explicit App ID** に対して **WeatherKit** を有効化する必要がある
- WeatherKit を有効化した直後は反映まで少し時間がかかるため、**しばらく待ってから再ビルド / 再インストール** する
- entitlement や利用条件が満たされない場合、天気 / 気温は **表示されずに自動スキップ** される

## 補足

- 内部 project / target / scheme 名は CI 安定性のため **`MyFirstApp`** を維持
- 表示名とプロダクト名は **`Resonance`**
- `.xcodeproj` はリポジトリに含めず、CI で毎回生成
