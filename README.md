# xcode-simulator-host

Xcode 27 の iOS Simulator 実行経路を、Device Hub と Xcode 26 の従来型
Simulator の間で切り替える macOS コマンドです。

Apple が公開していない Xcode 27 の設定を利用する実験的なツールです。対応範囲を
推測せず、選択中の Xcode、Device Hub、設定キーを検証できた場合だけ変更します。

## Install

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh
```

<details>
<summary>Other install options</summary>

インストール先を指定します。

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

versionを固定します。

```bash
curl -fsSL https://github.com/lynnswap/xcode-simulator-host/releases/download/v0.1.0/install.sh | sh
```

</details>

## Quick Start

Xcode 27を開いたまま実行できます。

```bash
xcode-simulator-host status
xcode-simulator-host use legacy
```

`use legacy` は設定変更後に、選択中のXcode 27に含まれるDevice Hubへ通常終了を
依頼し、検証済みのXcode 26内のSimulatorを開きます。そのままXcode 27のGUIから
Build & Runします。

Device Hub経路へ戻す場合もXcodeを終了する必要はありません。

```bash
xcode-simulator-host use device-hub
```

このツールを初めて実行する前の設定へ正確に戻すには、`restore` を使います。

```bash
xcode-simulator-host restore
```

`use device-hub` は Device Hub 用の標準状態（両方の上書き設定が存在しない状態）を
選びます。`restore` は、設定キーが存在しなかったか、明示的な `false` / `true`
だったかも含め、最初に保存した状態を復元します。

## Requirements

- macOS 26.4 以降（Xcode 27 の `LSMinimumSystemVersion` に合わせています）
- GitHub ReleasesのbinaryはApple Silicon
- Xcode 27（source buildにはSwift 6.4が必要）
- 従来型 Simulator 用の Xcode 26（`use legacy` のみ）

対象の Xcode 27 は `DEVELOPER_DIR`、未指定なら `xcode-select -p` から解決します。
たとえば `/Applications/Xcode_27.app` を一回だけ指定する場合は次のとおりです。

```bash
DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer \
  xcode-simulator-host status
```

従来型 Simulator は `/Applications` にある検証済み Xcode 26 のうち、最も新しい
ものを選びます。別の場所にあるXcodeを明示する場合は絶対パスを渡します。

```bash
xcode-simulator-host use legacy \
  --legacy-xcode /Applications/Xcode.app
```

`sudo` は使わないでください。このコマンドは現在のユーザーの Xcode 設定を管理します。

## Commands

```console
xcode-simulator-host status
xcode-simulator-host use legacy [--legacy-xcode /absolute/path/to/Xcode.app]
xcode-simulator-host use device-hub
xcode-simulator-host restore [--force]
```

- `status`: 選択中の Xcode、2つの設定値、Xcode 26 Simulator、復元情報、実行中の
  Xcode を表示します。実設定は変更しません。
- `use legacy`: Device Hub を経由しない CoreSimulator セッションを選び、Xcode 26
  の Simulator を開きます。実行中のDevice Hubは正常終了させます。
- `use device-hub`: 2つの上書き設定を削除し、Xcode 27 の標準 Device Hub 経路を
  選びます。
- `restore`: 最初の変更前に保存した2つの設定を復元します。live設定とreceiptが
  conflictしている場合は上書きしません。
- `restore --force`: conflictを確認したユーザーの明示操作として、保存済みの元設定を
  現在のBoolean値より優先します。

`use` と `restore` はXcodeの起動中にも設定を切り替えます。`use legacy` では設定の
commit後にDevice Hubの終了完了を待ち、設定がまだlegacyであることを再確認してから
Simulatorを開きます。最終確認からopen完了までは同じoperation lockを保持するため、
並行する別の切り替えが間へ入ることはありません。Device Hubの終了またはSimulatorの
起動だけに失敗した場合は、設定変更済みであることをpartial-successエラーに明記します。
その状態も `restore` で復元できます。

## Build from Source

依存には Apple の
[swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.8.2 を使います。

```bash
swift build -c release
.build/release/xcode-simulator-host --help
```

任意で、生成した実行ファイルを PATH 上のディレクトリへコピーできます。

```bash
install -d ~/.local/bin
install -m 755 .build/release/xcode-simulator-host ~/.local/bin/xcode-simulator-host
```

## Safety and recovery

初回変更前の値と進行中の変更は、次に保存します。

```text
~/Library/Application Support/xcode-simulator-host/state.plist
```

設定変更は排他ロック下で実行し、各値を読み戻してから完了とします。途中で失敗した
場合は直前の状態へロールバックします。外部から設定が変わって保存内容と一致しない
場合は conflict として停止し、推測で上書きしません。

receiptに記録した2設定の書き込み途中と同じ値が見つかっても、それがこのツールの
中断結果か外部変更かは証明できません。この場合も自動復旧せず、`status`は終了コード
`78`で曖昧な状態を表示します。receiptと現在値を確認し、保存済みの元設定を優先すると
判断した場合だけ `restore --force` を実行してください。Xcodeは開いたままで構いません。

終了コードはBSD `sysexits`に沿います。主な値は `0`（成功または仕様上のno-op）、
`64`（引数エラー）、`69`（対応するXcode/Simulatorなし）、`74`（I/O失敗）、
`75`（lock競合、またはDevice Hubの正常終了失敗）、`78`（設定不整合・receipt
conflict）です。
`status` はconflictの内容をstdoutへ表示し、`78`で終了します。

アンインストールや状態ファイルの削除より先に `restore` を実行してください。

Xcode の設定ドメイン `com.apple.dt.Xcode` はインストールごとではなく共有です。
このツールで選択した Xcode 27 は互換性確認の対象であり、設定の適用先をその
Xcode だけに限定するものではありません。

自動探索または `--legacy-xcode` で指定したXcodeとSimulatorは、bundle情報と実行
ファイルに加えてApple code signatureを検証します。外側はidentifier
`com.apple.dt.Xcode`、内側は `com.apple.iphonesimulator` とApple anchorを満たし、
Simulatorの署名済み `DTXcode` もmajor 26である場合だけ開きます。

終了対象のDevice Hubも、選択中Xcode内の検証済みbundle URLと完全一致するものに
限定します。同じbundle identifierを名乗る別pathのprocessは終了しません。終了要求後は
`NSRunningApplication.isTerminated` のKVOで完了を確認し、`NSWorkspace`のfull inventoryを
読み直します。再起動したinstanceを含めて最大10秒間、実行中の対象が0になるまで収束
させます。強制終了は行いません。

設計、管理する設定、トランザクション、失敗意味論の詳細は
[Documentation/Design.md](Documentation/Design.md) を参照してください。

## Development

テストは一時ディレクトリと偽の Xcode bundle を使い、実際の設定やアプリを変更しません。

```bash
swift test
```

release assetをローカルで作成・検証します。

```bash
scripts/build-release.sh --version v0.1.0
scripts/package-release.sh --version v0.1.0
scripts/verify-release-assets.sh \
  --version v0.1.0 \
  --repo lynnswap/xcode-simulator-host
```

GitHubではdefault branchの最新commitからworkflowをdispatchします。

```bash
gh workflow run release.yml --ref main -f version=v0.1.0
```

workflowはtagとassetを持つdraft releaseを作成します。release notesを確認してから
GitHub上で手動publishします。suffix付きversionはprereleaseとして作成され、
`releases/latest`のinstall経路には入りません。

## License

[LICENSE](LICENSE)
