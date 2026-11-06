# NeoSimulator

[English](README.md) | [Japanese](README.ja.md)

NeoSimulator は、iPhone、iPad、Apple Watch、Apple TV、Apple Vision Pro に対応した軽量シミュレーターアプリです。

![iPhone シミュレータとデバイス設定を表示した NeoSimulator](Documentation/Images/NeoSimulator.png)

## 動作環境

- Apple Silicon 搭載 Mac
- macOS 26.4 以降
- Xcode 27 以降（シミュレータのランタイムをインストール済みであること）

## インストール

[Releases](https://github.com/lynnswap/NeoSimulator/releases) から DMG をダウンロードして開き、**NeoSimulator.app** を **Applications** にドラッグします。

初期設定では、アプリの起動中に NeoSimulator でシミュレータを表示します。選んだ表示先の設定は終了後も維持します。表示先は **Settings → General → Preferred Display Host** で変更できます。

## ドキュメント

- [ユーザーガイド（英語）](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/)
- [CLI 版からの移行](Documentation/MigratingFromCLI.ja.md)
- [開発ガイド（英語）](Documentation/NeoSimulator.docc/Development.md)

## シミュレーターアプリを作る

Swift package の `NeoSimulatorKit` product から、シミュレーターの一覧取得、デバイスの
状態、起動・終了を、表示に依存せず利用できます。`NeoSimulatorUI` product はそれらの
デバイスを AppKit の画面に表示します。どちらも Swift 6.4 と、アプリと同じバージョンの
macOS・Xcode が必要です。

```swift
import NeoSimulatorKit
import NeoSimulatorUI

let context = try await SimulatorContext.load()
let devices = try await context.devices()
if let device = devices.first {
    _ = try await context.boot(device.id)
    let screens = try await SimulatorScreens(context: context)
    let screen = try await screens.open(device.id)
    try screen.showWindow()
    // 表示中は context、screens、screen を保持します。
}
```

AppKit のコンテナへ埋め込む場合は `SimulatorScreenViewController(screen:)` を
使います。`screen.session` は開いているデバイスを表し、そのモデル、ゲストへの操作、
オプションサービスの準備状態を持ちます。画面はこれらのサービスを待たずに使えるように
なり、サービスが失敗した場合は別の経路に切り替えず、失敗をそのまま伝えます。
`screen.close()` と `context.invalidate()` は表示や入力のリソースを解放し、ゲストは
起動したままにします。ゲストを終了する場合は `context.shutDown(_:)` を呼びます。
終了時のエラーを扱えるよう、これらの非同期処理が完了してからアプリを終了してください。

[MinimalSimulatorApp](Examples/MinimalSimulatorApp) は公開 API だけを使う独立した
サンプルです。終了処理と、画面の開閉を自動で検証する実行方法も含んでいます。

## 謝辞

バックグラウンドサービスの制御は、停止しても安全なサービスの一覧を含めて [simslim](https://github.com/MobAI-App/simslim) から移植しています。Interlap と [simslim のコントリビューター](https://github.com/MobAI-App/simslim/graphs/contributors)に感謝します。simslim は MIT ライセンスで公開されています。simslim の許諾表示と依存パッケージのライセンスは、**Settings → Licenses** で確認できます。

## ライセンス

[MIT](LICENSE)
