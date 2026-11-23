# ドットアトリエ

絵や写真を、ゲーム機の画面のようなドット絵に変えるiOSアプリ。変換はすべて端末内の計算だけで完結し、写真もドット絵も外部へ送らない。AIの学習も、権利の主張もしない。

Web版（[https://shodai4.com/dot-atelier/](https://shodai4.com/dot-atelier/)）と同じエンジン（5段階パイプライン）をSwiftへ移植し、iOS 17のVisionによるオンデバイス被写体切り抜きを加えている。

## 機能

1. **背景抜き** — 外周からのフラッドフィル（許容差つき）、Visionの被写体切り抜き（iOS 17+）、タップした色の透過。
2. **等倍1×透過PNG** — 32pxなら32×32のまま、透過を保って写真へ保存。
3. **シームレス3×3** — 左右・上下の端をなじませ、3×3に並べても継ぎ目が出ないタイルにする。プレビューで3×3を確認できる。
4. **一括変換／パレットロック** — 最大8枚。1枚目のパレットを残りへ引き継ぐ。
5. **1ドット修正** — ペン・消しゴム・スポイトでドットを直接描き直す。20手まで取り消せる。
6. **差分生成** — 2P色相（色相角は30〜330度）、白フラッシュ、黒影。
7. **スプライトシート結合** — 同じ大きさのフレームを横1列に結合。
8. **ゲーム機プリセット＋ディザ** — FC風16色、GB風4階調、PICO-8、ツクール48px（24色）、高精細64px（32色）。4×4ベイヤーディザの入切。

## 5段階パイプライン

| 段 | 内容 |
| --- | --- |
| 1 | エッジ保存平滑化（簡易バイラテラル、σ=38） |
| 2 | エッジ優先ダウンサンプリング（細い主線・瞳を残す） |
| 3 | Oklab K-Means++ 減色＋ヒューシフト（影は青紫、光は黄へ） |
| 4 | 孤立点掃除（透明に浮いた粒を削除、色だけ浮いた粒を近傍色へ）＋L字ダブルピクセル間引き |
| 5 | 1px輪郭線（黒／色トレス）＋差分バリエーション |

読み込み時に長辺512pxへ正規化し、減色のサンプルは最大4096点に間引く。端末で操作しながらでも待たされない密度にしている。

## 構成

| パス | 内容 |
| --- | --- |
| `project.yml` | XcodeGen 定義（Bundle ID `com.shodai4.dotatelier`、iOS 17.0+、Team `86WNUS2875`） |
| `Sources/DotAtelierApp.swift` | エントリポイント |
| `Sources/Models/PixelModels.swift` | プリセット・パレット・変換オプション・フレーム |
| `Sources/Services/PixelArtEngine.swift` | 5段階パイプライン、背景透過、差分、シート結合、等倍PNG化 |
| `Sources/Services/SubjectCutoutService.swift` | Vision の被写体切り抜き（iOS 17+、`#available` ガード） |
| `Sources/Services/PhotoSaver.swift` | 写真への追加のみ（`.addOnly`） |
| `Sources/Views/ContentView.swift` | ヘッダー、サイズ表示、パレット、一括サムネイル |
| `Sources/Views/PreviewArea.swift` | ドット／比較／3×3表示、1ドット操作の座標変換 |
| `Sources/Views/ControlDock.swift` | 変換・仕上げ・1ドット・書き出しの下部パネル |
| `Sources/Views/StudioModel.swift` | 状態、読み込み、再変換（デバウンス）、書き出し |
| `Sources/Views/CameraPicker.swift` | カメラ撮影 |
| `Sources/Views/Theme.swift` | 配色（アイボリー `#F9F8F5`／墨 `#1A1A1B`／錆青 `#4A6A7A`） |
| `Resources/Info.plist` | 写真・カメラの利用目的、暗号化の申告 |
| `Resources/PrivacyInfo.xcprivacy` | プライバシーマニフェスト（トラッキングなし・収集なし） |
| `scripts/ci-testflight.sh` | アーカイブ・書き出し・TestFlightアップロード |
| `scripts/dot_engine.py` | エンジンのPythonミラー（検証用） |
| `scripts/verify_logic.py` | ロジック単体テスト（111件） |
| `scripts/check_syntax.py` | Swift全ファイルの構文点検（tree-sitter） |
| `scripts/generate_icon.py` | アプリアイコン生成 |
| `ci/ios-build.yml` | GitHub Actions の定義（`.github/workflows/` へ設置する控え） |

## ローカル検証

```sh
python3 -m pip install tree-sitter tree-sitter-swift pillow
python3 scripts/verify_logic.py
python3 scripts/check_syntax.py
```

## CI

`ci/ios-build.yml` が test（ubuntu・計算と構文）→ build（macOS・署名なしコンパイル）→ testflight（クラウド署名でアップロード）の3ジョブを回す。必要なSecretsは `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` / `APP_STORE_CONNECT_PRIVATE_KEY` / `APPLE_TEAM_ID`。

## プライバシー

写真は端末内で処理し、送信しない。広告SDK・解析SDKは入れていない。写真へのアクセスは「追加のみ」で、既存の写真を読む権限は要求しない（読み込みはユーザーが選んだ写真だけ）。
