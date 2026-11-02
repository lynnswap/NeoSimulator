# CLI 版からの移行

[English](MigratingFromCLI.md) | [Japanese](MigratingFromCLI.ja.md)

設定やデータを手動で移す必要はありません。既存のシミュレータをそのまま使え、以前の NeoSimulator アプリの設定も初回起動時に引き継ぎます。CLI 版が保存した元の Xcode 設定も、引き続き復元に使えます。

1. 以前の NeoSimulator アプリを終了します。`xcode-simulator-host use legacy` を使っていた場合は、Xcode 26 の **Simulator** アプリを終了します。
2. [新しいアプリをインストール](../README.ja.md#インストール)し、**Settings** で **Preferred Display Host** を選びます。CLI の表示先切り替えコマンドは、この **NeoSimulator** と **Device Hub** の選択に置き換わります。Legacy モードはありません。

CLI 版の削除は任意で、新しいアプリが自動で削除することはありません。インストーラの既定の場所にインストールした場合は、次のコマンドで削除できます。

```bash
rm "$HOME/.local/bin/xcode-simulator-host"
rm -r "$HOME/.local/libexec/xcode-simulator-host"
```

インストール先を変更した場合は、その場所にあるファイルを削除してください。

`~/Library/Application Support/xcode-simulator-host/state.plist` は残してください。CLI 版が保存した元の Xcode 設定が入っており、新しいアプリの **Restore Original Settings…** で使います。
