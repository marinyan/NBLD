# NBLD v3 共通ローダ形式

`NBLD`は`N-BASIC Loader`の略称である。NBLD v3は、PC-8001系作品で
同一のN-BASIC第1段とZ80第2段を使うための
自己記述型パッケージ形式である。作品名、起動番地、メモリバンク、展開先、
展開長はローダーコードではなく`.nbld`パッケージへ格納する。

この共通ローダーを使用する作品のCSAVE名は、意図的にすべて`NBLD80`とする。
作品固有の名前はCSAVE名やローダーの分岐ではなく、パッケージ自身が名乗る。

## 固定配置

| アドレス | 内容 |
| --- | --- |
| `C800H`～ | Base64から復元したNBLDパッケージ |
| `F000H`～ | 共通第2段を移すための18バイトbootstrap |
| `F800H`～ | 共通NBLD第2段 |
| `FB00H` | 第2段のスタック上端 |

N-BASICプログラムは、共通第2段をDATA行から`C8C0H`へ復元する。
`F000H`のbootstrapが第2段を`F800H`へコピーした後、BASICプログラム中の
`REM D...`行をBase64デコードして`C800H`へ置く。`REM E`が入力終端である。

## 32バイト固定ヘッダー

```text
offset  size  meaning
00H     4     ASCII "NBLD"
04H     1     format version = 03H
05H     1     header size = 20H
06H     2     package total length, little endian
08H     2     entry address, little endian
0AH     1     segment count (1..255)
0BH     1     flags, currently 00H
0CH     16    display name, ASCII, NUL padded
1CH     4     reserved, must be 00H
```

表示名は最大15文字とし、16バイト内に必ずNULを含める。たとえば`MYPROGRAM`を格納する。

## セグメント

ヘッダー直後に、ヘッダーの`segment count`個だけ次のレコードを置く。

```text
offset  size  meaning
00H     1     value written to memory-control port 31H
01H     1     codec (01H = common LZSS12)
02H     2     destination address, little endian
04H     2     expanded length, little endian
06H     2     packed length, little endian
08H     n     packed bytes
```

LZSS12は8項目ごとに1バイトのフラグを置き、bit 0から順に読む。
bitが1なら後続1バイトをそのまま出力する。bitが0なら後続2バイトで
12bitの後方距離と`3..18`バイトの長さを表す。

第2段は各セグメントの直前にport `31H`へ指定値を出力する。全セグメントの
展開後は`00H`を出力して通常のN80 ROM配置へ戻し、ヘッダーのentry addressへ
ジャンプする。このためROM裏RAMを使う作品も、通常RAMだけを使う作品も、
ローダーコードを変更せずセグメント記述だけで表現できる。

## 共通化の境界

利用する各プロジェクトで同一に保つものは次である。

- NBLD v3のバイト形式
- N-BASIC第1段のコードとCSAVE名`NBLD80`
- `F000H`bootstrap
- `F800H`第2段
- Base64とLZSS12の実装
- パッケージ検査と展開手順

作品ごとに異なるのは、表示名、entry address、セグメント記述、圧縮対象の
バイナリだけである。新作を追加するとき、共通ローダーへ作品名による分岐を
追加してはならない。

## 共有コードの更新方針

共通ローダーは変更禁止ではない。変更する場合は利用する各プロジェクトの
共有コピーを同時に揃え、各作品のCLOAD→RUNとセグメント展開を検証する。
作品ごとの例外分岐を増やさず、共有する基本ロジックを意図的に維持する。

2026-09-05更新では、LZSS圧縮を最長一致の貪欲選択から、8トークンごとのフラグ費用も
含めた最小サイズの選択へ変更した。12bit距離の全候補と3～18バイトの一致長を調べる。
また18バイトのbootstrapを設定するPOKEを1つのBASIC行にまとめ、任意の空白を省いて
34バイト節約した。NBLD v3形式、Z80第2段631バイト、メモリ配置、安全条件は変更していない。
圧縮後の往復一致と、前向き展開が未読入力を壊さない検査は引き続きビルド時に実施する。

2026-09-09: [容量拡張と全利用先の検証](capacity-2026-09-09.md)。

ローダー領域への初期値付きデータは、[最終コピー](finalizer-ja.md)を指定して配置できる。
NBLD v3形式は維持し、追加の通常セグメントとentryの付け替えで実現する。
