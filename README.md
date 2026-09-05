# NBLD — N-BASIC Loader

PC-8001 系プロジェクトで使う共通ローダー。N-BASIC 第1段と Z80 第2段で、
Base64 化した NBLD v3 パッケージを復元し、LZSS12 圧縮された各セグメントを
指定バンク・番地へ展開してエントリーポイントへジャンプする。

## 構成

- `tools/nbld/build_nbld_loader.ps1`: パッケージ、N-BASIC、CMT、T88 の生成
- `tools/nbld/nbld_stage2.asm`: 共通 Z80 第2段
- [NBLD v3 形式仕様](docs/nbld-v3-ja.md): メモリ配置・パッケージ形式・共有方針

## ビルド

PowerShell と、元プロジェクトで使う `z80asm.exe` が必要。
アセンブラは `-o`、`-l`、`--sym`、`--cpu z80` に対応するものを使う。
`-AssemblerPath` は利用環境に合わせて明示する（スクリプトの既定値は取込元の環境）。

プロジェクトのバイナリを用意し、このリポジトリのルートから実行する。

```powershell
$segments = @(
    [pscustomobject]@{
        Path = 'C:\path\to\program.bin'
        MemoryControl = 0x00
        Destination = 0x8000
    }
)
& ./tools/nbld/build_nbld_loader.ps1 `
    -AssemblerPath 'C:\path\to\z80asm.exe' `
    -PayloadName 'MYPROGRAM' `
    -EntryAddress 0x8000 `
    -Segments $segments `
    -OutputStem 'myprogram' `
    -OutputDirectory ./build
```

表示名は最大15文字の ASCII（ダブルクォートを除く印字可能文字）で、大文字に変換される。
CSAVE 名は全作品で `NBLD80`。生成した `*-basic.t88` または `*-basic.cmt` を
対応エミュレーターでセットし、N-BASIC から `CLOAD` → `RUN` で起動する。
`*-loader.bas` は確認用の表示で、ペイロードの REM 行を省略しているため、
配布・ロードには生成されたテープイメージを使う。

ビルド時に圧縮・展開の往復一致、前向き展開による未読入力の上書き、
パッケージと共通第2段の重なり、BASIC の作業領域を検査する。
搭載 RAM・バンク構成と展開番地は対象機種に合わせて設定する。

## 共通コードの方針

作品固有の設定は呼び出し側のセグメント記述に置き、共通コードへ作品名の分岐を追加しない。
