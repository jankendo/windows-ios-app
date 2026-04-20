# Resonance を Windows から開発する環境

このリポジトリは、**Windows で SwiftUI ソースを編集し、GitHub Actions の macOS ランナーで iOS アプリ `Resonance` の IPA を生成する**ための構成です。署名素材が有効なら署名付き IPA を出力し、署名素材が無い・壊れている・失効している場合でも、**Sideloadly で再署名できる unsigned IPA** まで自動で作ります。

## この構成でできること

1. Windows 上で `Resonance` の SwiftUI / SwiftData コードを編集する
2. GitHub の **Public** リポジトリへ push する
3. GitHub Actions で Xcode プロジェクトを自動生成して archive / export する
4. 署名済みまたは Sideloadly 用 unsigned IPA を Artifact として取得する
5. iPhone / iPad で写真 + 環境音メモリーアプリを動かす

## Resonance MVP の内容

現状のアプリは、未来 API 依存ではなく**現行 iOS SDK で動く MVP**として実装しています。

1. 写真撮影と 6 秒の環境音キャプチャ
2. `SwiftData` へのメモリー保存
3. `Vision` / `SoundAnalysis` / `Speech` を使った自動タグ付け
4. ライブラリ一覧、詳細表示、音声再生、編集、削除
5. タイトル / メモ / タグ / 文字起こし / ムードを横断する検索

## 先に準備するもの

| 項目 | 用途 |
| --- | --- |
| Git for Windows | リポジトリ操作 |
| VS Code + Swift 拡張 | コード編集 |
| Apple Developer 無料アカウント | 開発証明書とプロファイル作成 |
| 一度だけ使える Mac またはクラウド Mac | `.p12` と `.mobileprovision` 作成 |
| GitHub Public リポジトリ | 無料の macOS ホストランナー利用 |
| Sideloadly + Apple公式配布版 iTunes | 実機インストール |

## リポジトリ構成

```text
.
├─ .github/
│  └─ workflows/
│     └─ build-ios.yml
├─ Config/
│  └─ project.yml
├─ local-secrets/
│  ├─ build-certificate-base64.txt
│  └─ build-provision-profile-base64.txt
├─ Sources/
│  ├─ AudioPlayerController.swift
│  ├─ CameraCaptureService.swift
│  ├─ CaptureView.swift
│  ├─ ContentView.swift
│  ├─ Info.plist
│  ├─ LibraryView.swift
│  ├─ MediaStore.swift
│  ├─ MemoryAnalysisService.swift
│  ├─ MemoryDetailView.swift
│  ├─ MyFirstAppApp.swift
│  ├─ ResonanceModels.swift
│  ├─ SearchView.swift
│  └─ WaveformView.swift
└─ scripts/
   ├─ encode-signing-assets.ps1
   ├─ complete-github-setup.ps1
   ├─ publish-github-secrets.ps1
   └─ run-swift-in-dev-env.ps1
```

## 必ず置き換える値

### 1. Bundle ID

現在のプロビジョニングプロファイルは **`a.export.*`** のワイルドカード構成だったため、既定値はその範囲内の具体値に合わせてあります。

```yaml
PRODUCT_BUNDLE_IDENTIFIER: a.export.myfirstapp
```

別の Bundle ID を使う場合も、**必ず `a.export.` で始まる具体値**にしてください。GitHub Actions はワイルドカードプロファイルを検出したとき、この値がプロファイル範囲内か検証してからビルドします。

### 2. アプリ名と内部ターゲット名

表示名は `Resonance` です。
一方で、**CI の安定性維持のため内部の project / target / scheme 名は `MyFirstApp` のまま**にしています。

1. 表示名: `Sources/Info.plist` の `CFBundleDisplayName = Resonance`
2. 実行バイナリ名: `Config/project.yml` の `PRODUCT_NAME = Resonance`
3. 内部 project / target / scheme 名: `MyFirstApp`
4. ワークフロー内の `APP_NAME`: `MyFirstApp`

## Apple署名素材の準備

最低一度は Mac 環境で次を取得してください。

1. `Certificates.p12`
2. `.p12` を書き出したときのパスワード
3. `xxxx.mobileprovision`
4. `Team ID`

今回見つかったプロファイルから読み取れた値は次の通りです。

| 項目 | 値 |
| --- | --- |
| Team ID | `2M6M6BW775` |
| Team Name | `Tunaib Hajeef` |
| Profile Name | `a` |
| Profile UUID | `db29cebe-1df1-4eca-9d26-322874c92ad8` |

### Mac での作成手順

1. Apple Developer に Apple ID でサインインし、無料アカウントを有効化します。
2. Mac の **キーチェーンアクセス** を開き、`キーチェーンアクセス > 証明書アシスタント > 認証局に証明書を要求...` から CSR を作成します。
3. Apple Developer の `Certificates, Identifiers & Profiles > Certificates` で **Apple Development** 証明書を作成し、ダウンロードします。
4. ダウンロードした証明書をキーチェーンへ追加し、**自分の証明書** から `.p12` 形式で書き出します。このときのパスワードが `P12_PASSWORD` です。
5. iPhone / iPad の UDID を Apple Developer の `Devices` に登録します。
6. `Identifiers` で明示的な App ID を作成します。ここで決めた Bundle ID を `Config/project.yml` に反映します。
7. `Profiles` で **iOS App Development** プロビジョニングプロファイルを作成し、`.mobileprovision` をダウンロードします。
8. Apple Developer の Membership 情報から `Team ID` を確認します。

> Mac を持っていない場合は、友人の Mac を一時利用するか、クラウド Mac を短時間だけ使えば十分です。

## Base64化

署名ファイルはコミットせず、PowerShell スクリプトで Base64 に変換します。

```powershell
pwsh -File .\scripts\encode-signing-assets.ps1 `
  -P12Path C:\path\to\Certificates.p12 `
  -ProvisioningProfilePath C:\path\to\profile.mobileprovision
```

出力先は `.\local-secrets\` です。ここは `.gitignore` 済みです。

## Swift のローカル実行

このPCでは、Swift 6.3.1 をそのまま起動すると Windows SDK 解決で不安定だったため、**Visual Studio 開発者環境 + 追加した Windows SDK** を通すラッパーを用意してあります。

```powershell
pwsh -File .\scripts\run-swift-in-dev-env.ps1 --version
```

Swift コマンドを直接叩く代わりに、必要なら次のようにラップしてください。

```powershell
pwsh -File .\scripts\run-swift-in-dev-env.ps1 build
```

## GitHub Secrets

GitHub リポジトリの `Settings > Secrets and variables > Actions` に次を登録します。

| Secret名 | 必須 | 値 |
| --- | --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 必須 | `local-secrets\build-certificate-base64.txt` の中身 |
| `P12_PASSWORD` | 必須 | `.p12` の書き出しパスワード |
| `BUILD_PROVISION_PROFILE_BASE64` | 必須 | `local-secrets\build-provision-profile-base64.txt` の中身 |
| `TEAM_ID` | 任意 | Apple Developer の Team ID。未設定時はプロファイルから自動取得 |

GitHub CLI (`gh`) を使える場合は、手動登録の代わりに次で投入できます。

```powershell
pwsh -File .\scripts\publish-github-secrets.ps1 `
  -Repository YOUR_GITHUB_NAME/YOUR_REPOSITORY `
  -P12Password 'YOUR_P12_PASSWORD' `
  -TeamId 2M6M6BW775
```

> `gh auth login` 済みであることが前提です。`TEAM_ID` は省略可能です。

GitHub CLI 自体はこのPCに導入済みです。未ログインの場合だけ、最初に `gh auth login` を実行してください。

Secrets 登録から remote 設定、初回 push までまとめて流す場合は次を使えます。

```powershell
pwsh -File .\scripts\complete-github-setup.ps1 `
  -Repository YOUR_GITHUB_NAME/YOUR_REPOSITORY `
  -P12Password 'YOUR_P12_PASSWORD' `
  -CreateRepository `
  -Public
```

すでに GitHub 上に空リポジトリがある場合は、`-CreateRepository` を外してください。

## GitHub Actions の動き

ワークフローは次を自動で行います。

1. `xcodegen` をインストール
2. `Config/project.yml` から内部 project `MyFirstApp.xcodeproj` を生成
3. まず **iOS Simulator 向けの署名なしビルド** で、構成自体が正しいかを毎回検証
4. Secrets が揃っていて有効なら、証明書とプロファイルを復元
5. 一時キーチェーンへ証明書を投入
6. プロファイルから Bundle ID / Profile名 / Team ID を抽出
7. 署名付き `xcodebuild archive` / `xcodebuild -exportArchive` を試行
8. 署名に失敗した場合は、`CODE_SIGNING_ALLOWED=NO` で unsigned IPA を自動生成
9. `*.ipa` を Artifact として保存
10. 一時キーチェーンを削除

### Secrets 未設定時の挙動

- ワークフローは **unsigned IPA の生成へ自動フォールバック** します。
- そのため、Apple 署名素材をまだ用意できていなくても、XcodeGen と SwiftUI ソースの整合性確認だけで止まらず、Sideloadly 用の `.ipa` まで取得できます。
- 有効な署名素材を追加すると、同じワークフローで signed IPA の生成も自動で試みます。

## 初回セットアップ

```powershell
git init -b main
git add .
git commit -m "Initial Windows iOS build scaffold"
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

> すでに GitHub 上で空リポジトリを作成済みなら、この手順で紐付けできます。

## 実機インストール

1. GitHub Actions の実行完了後、`ios-app-ipa` Artifact をダウンロード
2. ZIP を展開して `.ipa` を取り出す
3. iPhone を USB 接続して Sideloadly を起動
4. `.ipa` をドラッグ＆ドロップしてインストール
5. iPhone の `設定 > 一般 > VPNとデバイス管理` で Apple ID を信頼

### Sideloadly の補足

- Windows では Microsoft Store 版ではなく、Apple 公式配布版の iTunes を使ってください。
- Artifact が unsigned IPA でも、Sideloadly 側で Apple ID 署名してインストールできます。
- 初回インストール直後は、ホーム画面のアプリを開く前に **VPNとデバイス管理** で Apple ID を信頼する必要があります。

## 重要な補足

- この構成は **Windows上でXcodeを使わずに編集** するためのものです。実際の iOS ビルドは GitHub の macOS ランナーで行います。
- `.xcodeproj` は GitHub Actions で毎回生成するため、リポジトリに含めません。
- 無料枠前提では GitHub リポジトリを Public にしてください。

