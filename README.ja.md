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

起動時は毎回 NeoSimulator を優先します。その起動中に Device Hub を使いたい場合は、**Settings → General → Preferred Display Host** で選択できます。Device Hub を直接開いても選択は変わらず、NeoSimulator を選択していれば Device Hub の終了後に表示を引き継ぎます。NeoSimulator を終了しても Xcode の表示先設定は戻しません。

## ドキュメント

- [ドキュメントのトップ（英語）](https://lynnswap.github.io/NeoSimulator/documentation/)
- [ユーザーガイド（英語）](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/)
- [CLI 版からの移行](Documentation/MigratingFromCLI.ja.md)
- [コントリビューションガイド（英語）](CONTRIBUTING.md)
- [SDK ガイド（英語）](https://lynnswap.github.io/NeoSimulator/documentation/neosimulator/usingthesdk)
- API リファレンス（英語）: [NeoSimulatorKit](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorkit/)、[NeoSimulatorUI](https://lynnswap.github.io/NeoSimulator/documentation/neosimulatorui/)

## 謝辞

バックグラウンドサービスの制御は、停止しても安全なサービスの一覧を含めて [simslim](https://github.com/MobAI-App/simslim) から移植しています。Interlap と [simslim のコントリビューター](https://github.com/MobAI-App/simslim/graphs/contributors)に感謝します。simslim は MIT ライセンスで公開されています。simslim の許諾表示と依存パッケージのライセンスは、**Settings → Licenses** で確認できます。

## ライセンス

[MIT](LICENSE)
