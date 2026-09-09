# NBLD — N-BASIC Loader

PC-8001 系プロジェクトで使う共通ローダー。N-BASIC 第1段と Z80 第2段で、
Base64 化した NBLD v3 パッケージを復元し、LZSS12 圧縮された各セグメントを
指定バンク・番地へ展開してエントリーポイントへジャンプする。

## 構成

- `tools/nbld/build_nbld_loader.ps1`: パッケージ、N-BASIC、CMT、T88 の生成
- `tools/nbld/nbld_stage2.asm`: 共通 Z80 第2段
- [NBLD v3 形式仕様](docs/nbld-v3-ja.md): メモリ配置・パッケージ形式・共有方針

## ビルド

PowerShell と、SjASMPlus または従来の `z80asm` が必要。

### SjASMPlus（既定）

[SjASMPlus](https://github.com/z00m128/sjasmplus) を使用する。
動作確認版は [1.24.0](https://github.com/z00m128/sjasmplus/releases/tag/v1.24.0)。
Windows では公式リリースの `sjasmplus-1.24.0.win.zip` を展開し、
`sjasmplus.exe` を `-AssemblerPath` で指定する。
PATH に登録してある場合は `-AssemblerPath` を省略できる。
アセンブラ本体はこのリポジトリに同梱しない。

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
    -AssemblerPath 'C:\path\to\sjasmplus.exe' `
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

第2段だけをアセンブルする場合は次のとおり。

```powershell
New-Item -ItemType Directory -Force ./build | Out-Null
sjasmplus --raw=build/nbld_stage2.bin tools/nbld/nbld_stage2.asm
```

第2段は631バイトで、SjASMPlus 1.24.0とz80asmの出力はバイト単位で一致する。
SHA-256: `02df5a4134b83c8bdc329291cfd9b238c8022acd677c0febe4da67daf27e4afd`。
`ORG F800H` は実行番地であり、生バイナリの先頭に F800H バイトのパディングは付かない。

### 従来の z80asm

従来使用している `z80asm.exe` も `-Assembler z80asm` で選択できる。
上記と同じ `$segments` を用意し、次のように実行する。

```powershell
& ./tools/nbld/build_nbld_loader.ps1 `
    -Assembler z80asm `
    -AssemblerPath 'C:\path\to\z80asm.exe' `
    -PayloadName 'MYPROGRAM' `
    -EntryAddress 0x8000 `
    -Segments $segments `
    -OutputStem 'myprogram' `
    -OutputDirectory ./build
```

PATH に登録してある場合は `-AssemblerPath` を省略できる。
このモードは `source.asm -o output.bin -l listing.lst --sym symbols.sym --cpu z80`
という引数を受け付ける従来版向け。同名で配布されている別の `z80asm` との互換性は保証しない。
実行ファイル名からの自動判別は行わないので、従来版では `-Assembler z80asm` も指定する。

第2段だけをアセンブルする場合は次のとおり。

```powershell
New-Item -ItemType Directory -Force ./build | Out-Null
& 'C:\path\to\z80asm.exe' tools/nbld/nbld_stage2.asm `
    -o build/nbld_stage2.bin -l build/nbld_stage2.lst `
    --sym build/nbld_stage2.sym --cpu z80
```

## 共通コードの方針

作品固有の設定は呼び出し側のセグメント記述に置き、共通コードへ作品名の分岐を追加しない。

2026-09-09: [容量拡張と全利用先の検証](docs/capacity-2026-09-09.md)。

初期値付きデータでローダー自身を最後に上書きする場合は、
[最終コピー](docs/finalizer-ja.md)の -AllowLoaderOverwrite を使用できます。
