# GitHub Actions の控え

- 本体は `ci/ios-build.yml`。GitHub App に `workflows` 権限がないため、このリポジトリへの push では `.github/workflows/` へ置けない。
- ブラウザで `ci/ios-build.yml` の内容を `.github/workflows/ios-build.yml` として1回だけ置くと、以降は `main` への push ごとに test → build → testflight が回る。

必要なリポジトリ Secrets（TestFlight 配信用）:

| Secret | 内容 |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API キーの Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | AuthKey_\*.p8 の中身 |
| `APPLE_TEAM_ID` | チーム ID（86WNUS2875） |
