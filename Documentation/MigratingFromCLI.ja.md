# CLI 版からの移行

[English](MigratingFromCLI.md)

以前の NeoSimulator を終了します。`xcode-simulator-host use legacy` を使っていた場合は、Xcode 26 の Simulator も終了してください。[NeoSimulator をインストール](../README.ja.md#インストール)して起動すると、既存のシミュレータと NeoSimulator の設定を引き継げます。

古い CLI は削除できます。既定の場所にインストールした場合は、次のコマンドを使います。

```sh
rm "$HOME/.local/bin/xcode-simulator-host"
rm -r "$HOME/.local/libexec/xcode-simulator-host"
```

`~/Library/Application Support/xcode-simulator-host/state.plist` は残してください。**Restore Original Settings…** で、CLI が保存した Xcode の設定を復元するときに使います。
