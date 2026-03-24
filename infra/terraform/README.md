# Terraform GCP 運用ランブック（Apply + Destroy）

このランブックは `infra/terraform` で構築する SCEP 検証環境の作成・検証・破棄手順をまとめたものです。
Terraform による `scep-server` 側のプロビジョニングを前提とし、Windows クライアント側は現状どおり手動実行を含む運用です。

## この環境での検証範囲

- **このワークスペースで確認済み:** ドキュメント内のパス・リンク、スクリプト引数、手順フロー、主要コマンドの整合性。
- **実環境 GCP で要確認:** `terraform plan/apply/destroy`、VM 起動スクリプト実行結果、ネットワーク到達性、SSH/RDP 接続、実インフラ上での証明書発行 E2E。

## 前提条件

- Terraform `>= 1.5.0, < 2.0.0`（`versions.tf`）
- `gcloud` CLI（`ssh` / シリアルログ確認 / Windows パスワード再設定で利用）
- GCP で VPC / Firewall / VM を作成できる権限
- Terraform Provider が参照できる ADC（Application Default Credentials）
- `./scripts/linux/build_and_scp_scepserver.sh` を使う場合は `go` と `gcloud` が必要
- Windows MSI をローカルで作る場合は `cargo`, `rustup`, `x86_64-w64-mingw32-gcc`, `wixl` が必要

### GCP 認証モデル（ADC 限定）

1. オペレーターとして `gcloud` にログインし、対象プロジェクトを設定します。
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project <PROJECT_ID>
   ```
2. Terraform Provider は `provider.tf` で ADC をそのまま利用します。`credentials_file` や `GOOGLE_APPLICATION_CREDENTIALS` の追加設定はサポート対象にしません。
3. 古い checkout や手元の `terraform.tfvars` に `credentials_file = ...` が残っている場合は削除してください。

### シークレット管理の注意（必須）

- ADC 取得に使う認証情報の中身をドキュメント、ログ保存対象のターミナル、Issue/PR コメントに貼り付けないでください。
- 秘密値入り `terraform.tfvars` を Git にコミットしないでください。
- 組織で利用可能なら長期固定キーより短命クレデンシャルや秘密情報管理基盤を優先してください。

## `terraform.tfvars` の準備

1. 変数ファイルを作成します。
   ```bash
   cd infra/terraform
   cp terraform.tfvars.example terraform.tfvars
   ```
2. 少なくとも以下を更新します。
   - `project_id`, `region`, `zone`
   - `mysql_password`（必要に応じて `scep_ca_pass`）
   - `ssh_source_ranges`, `rdp_source_ranges`, `scep_source_ranges` を最小 CIDR に絞る
      - `scep_source_ranges` には、オペレーター端末のグローバル IP（例: `203.0.113.10/32`）を含めてください。
3. `scep_dsn` は手動上書きが必要な場合のみ設定し、通常は空のままにします。

> 注意: `mysql_password` は起動時 SQL に展開されるため、単一引用符 `'` を含める場合はブートストラップロジックの調整が必要です。

## Apply フロー（Terraform + SCP で `scepserver` 配備）

1. インフラを作成します。
   ```bash
   cd infra/terraform
   terraform init
   terraform validate
   terraform plan -var-file=terraform.tfvars -out=tfplan
   terraform apply tfplan
   terraform output
   ```
2. Linux 用 `scepserver` をローカルでビルドし、SCP でサーバー VM に配備します。
   ```bash
   ./scripts/linux/build_and_scp_scepserver.sh
   ```
   このスクリプトは `infra/terraform` の Terraform 出力から `project_id` / `deployment_zone` / `server_instance_name` を自動検出します。
  Linux コンテナや Cloud Shell 互換環境など `root` ユーザーで実行している場合は、SSH ユーザー名を active な `gcloud` アカウントから自動導出します。必要なら `--ssh-user <USERNAME>` で上書きしてください。
   **そのため `terraform apply` 実行済みで、`terraform output` が取得できる状態が前提です。**
   デフォルト構成外で使う場合は `--terraform-dir <PATH>` を指定し、必要に応じて `--project` / `--zone` / `--instance` で上書きしてください。
   OpenSSH/SCP が使えない場合、この helper は自動で一時 GCS + Linux startup-script fallback に切り替え、シリアルログの `COPILOT_SCEPSERVER_DEPLOY_DONE` を待ってから元の startup script を復元します。
3. サーバー疎通を確認します。
   ```bash
   SERVER_IP="$(terraform output -raw server_external_ip)"
   curl -fsS "http://${SERVER_IP}:3000/admin/api/ping"
   ```

`outputs.tf` で主に使う出力:
- `server_external_ip`
- `client_external_ip`
- `server_instance_name`, `client_instance_name`
- `deployment_zone`, `project_id`
- `server_internal_ip`, `client_internal_ip`

## サーバーブートストラップ確認

`terraform apply` と SCP 配備後に以下を確認します。

1. 許可済み送信元から SCEP エンドポイントを確認:
   ```bash
   SERVER_IP="$(terraform output -raw server_external_ip)"
   curl -fsS "http://${SERVER_IP}:3000/admin/api/ping"
   curl -fsS "http://${SERVER_IP}:3000/scep?operation=GetCACaps"
   ```
   `scep_source_ranges` を内部 CIDR のみにすると（例: `10.42.0.0/24` のみ）、オペレーター端末からはタイムアウトします。
2. Linux VM サービス状態を確認:
   ```bash
   gcloud compute ssh scep-server-vm --zone <ZONE> --project <PROJECT_ID> --command 'sudo systemctl status mysql scep-server --no-pager'
   ```
3. ブートストラップ異常時は起動ログを確認:
   - `gcloud compute instances get-serial-port-output`
   - `/var/log/syslog`
   - `journalctl -u scep-server -u mysql --no-pager`

## windows クライアント

RDP接続後に手動で接続する手段(A)と、シェルスクリプトで動作テストを行う手段(B)を記述します。

## A.1. 接続情報の取得（手元端末）

```bash
cd infra/terraform
CLIENT_INSTANCE="$(terraform output -raw client_instance_name)"
CLIENT_IP="$(terraform output -raw client_external_ip)"
ZONE="$(terraform output -raw deployment_zone)"
PROJECT_ID="$(terraform output -raw project_id)"
SERVER_IP="$(terraform output -raw server_external_ip)"
```

## A.2. Windows ログイン情報の取得（手元端末）

```bash
gcloud compute reset-windows-password "$CLIENT_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID"
```

表示されたユーザー名/パスワードで `CLIENT_IP` に RDP 接続してください。

## A.3. テスト時のみ: Linux 手元端末で MSI をローカル作成し、必要なら Windows VM へ転送

> 本番環境では MSI 配布は別途実施してください。以下は検証用途のみです。Windows 側の操作を最小化するため、MSI の生成は Linux 手元端末で完結させます。

1. Linux の手元端末で必要な依存を入れます。

```bash
cd <this-repo>
sudo apt-get update
sudo apt-get install -y gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64 msitools wixl wixl-data
rustup target add x86_64-pc-windows-gnu
```

2. Windows へコピーするユーザー名を控えます。

```bash
cd infra/terraform
gcloud compute reset-windows-password "$CLIENT_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID"
```

この出力の `username` を `WINDOWS_USER` として使います。

3. Linux の手元端末で MSI をローカル作成します。

```bash
cd <this-repo>

./infra/terraform/scripts/linux/build_windows_msi.sh
```

このスクリプトは以下を自動実行します。

- `rust-client/service` の `service.exe` クロスビルド
- `build/windows-msi` への `wixl` 入力ステージング
- `build/windows-msi/installer/dist/MyTunnelApp.msi` の生成

4. 生成した MSI をそのまま Windows VM に転送したい場合は、同じスクリプトに `--windows-user` を付けます。

```bash
cd <this-repo>
WINDOWS_USER="<reset-windows-passwordで取得したユーザー名>"

./infra/terraform/scripts/linux/build_windows_msi.sh --windows-user "$WINDOWS_USER"
```

`--windows-user` を付けた場合、スクリプトは Terraform 出力から `project_id`, `deployment_zone`, `client_instance_name` を自動検出し、まず Windows VM のホームへ `~/MyTunnelApp.msi` として SCP 転送を試みます。
Windows 側で OpenSSH が有効でない場合は、自動で fallback して一時 GCS 配布 + Windows startup script + VM 再起動を使い、`C:\Users\Public\MyTunnelApp.msi` へ配置します。

5. 手動で転送したい場合は、OpenSSH が有効な Windows VM へはローカル生成後に MSI だけを SCP 転送できます。

```bash
cd <this-repo>
WINDOWS_USER="<reset-windows-passwordで取得したユーザー名>"
MSI_PATH="$(pwd)/build/windows-msi/installer/dist/MyTunnelApp.msi"

gcloud compute scp "$MSI_PATH" "${WINDOWS_USER}@${CLIENT_INSTANCE}:~/MyTunnelApp.msi" \
  --zone "$ZONE" \
  --project "$PROJECT_ID"
```

## A.4. インストールと起動（Windows VM / 管理者 PowerShell）

ローカル Linux ビルドで生成する MSI は `wixl` ベースの silent-install 用パッケージです。
このため、Windows VM 側では GUI 入力ではなく `msiexec` のプロパティ指定でインストールします。

現時点の `wixl` パッケージでは WiX v4 側のような registry ACL 付与を同等に表現できないため、silent MSI だけは Windows Service を `LocalSystem` で登録します。
GUI MSI (`installer/main.wxs`) は引き続き `LocalService` + registry ACL 付与を source of truth とし、silent MSI は GCP 検証を前進させるための実用優先構成です。

### A.4-1. サイレントインストール

```powershell
$MsiPathCandidates = @(
  "$env:USERPROFILE\MyTunnelApp.msi",
  'C:\Users\Public\MyTunnelApp.msi'
)
$MsiPath = $MsiPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$ServiceUrl = "http://<SCEP_SERVER_IP>:3000/scep"

if (-not $MsiPath) {
  throw "MSI not found in expected paths: $($MsiPathCandidates -join ', ')"
}

New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null

  $arguments = @(
    "/i `"$MsiPath`"",
    "SERVER_URL=`"$ServiceUrl`"",
    "CLIENT_UID=`"client-001`"",
  "ENROLLMENT_SECRET=`"one-time-secret`"",
  "DEVICE_ID_OVERRIDE=`"device-001`"",
  "POLL_INTERVAL=`"1h`"",
  "RENEW_BEFORE=`"14d`"",
  "LOG_LEVEL=`"info`"",
  "/qn",
  "/norestart"
) -join ' '
Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -NoNewWindow
```

`SERVER_URL` は Terraform 出力の `server_external_ip` を使って以下のように設定してください。

- 例: `http://<SERVER_IP>:3000/scep`
- 互換用に MSI 内には旧 `SERVICE_URL` property も残していますが、この手順では `SERVER_URL=...` を指定してください。
- `DEVICE_ID_OVERRIDE` は本来検証環境向け override ですが、現フェーズでは自動 `device_id` 導出が未実装のため必須です。

現状の MSI は non-secret 設定をレジストリへ保存し、`ENROLLMENT_SECRET` はインストール直後にサービスが `EnrollmentSecretProtected` へ移行する前提で短時間だけレジストリへステージングします。
WiX だけで直接 DPAPI 化しているわけではない点は現フェーズの制約です。
silent MSI は `LocalSystem` 実行のため registry secret の DPAPI 移行と cleanup を行えますが、将来的には GUI MSI と同じ `LocalService` 運用へ寄せ直す前提です。

### A.4-2. Linux から startup-script 経由で silent install を走らせる

Windows VM が OpenSSH を受け付けない場合は、ローカル Linux 端末から startup-script を一時差し替えて silent install を実行できます。
この helper は `terraform output` から `project_id`, `deployment_zone`, `client_instance_name`, `server_external_ip` を自動解決し、シリアルログに install / verify のマーカーを出しながら待機します。

```bash
cd infra/terraform
SERVER_IP="$(terraform output -raw server_external_ip)"

cd <this-repo>
./infra/terraform/scripts/linux/install_windows_msi.sh \
  --client-uid "client-001" \
  --enrollment-secret "one-time-secret" \
  --device-id-override "device-001"
```

補足:

- 既定では `C:\Users\Public\MyTunnelApp.msi` を install 対象にするため、先に `build_windows_msi.sh --windows-user ...` などで MSI を Windows VM へ転送しておいてください。
- helper は一時的に enrollment secret を startup-script metadata へ埋め込みます。これは GCP 検証用の one-time secret 前提で使い、実行後は元の startup script へ戻します。
- シリアルログでは `MYTUNNEL_MSI_INSTALL_DONE` / `MYTUNNEL_MSI_INSTALL_FAILED` を確認できます。

## A.5. 動作確認（Windows VM / 管理者 PowerShell）

### A.5-1. レジストリ確認

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\MyTunnelApp' -Name ServerUrl,ConfigURL,ClientUid,DeviceId,DeviceIdOverride,PollInterval,RenewBefore,LogLevel,EnrollmentSecretProtected -ErrorAction SilentlyContinue
```

### A.5-2. サービス状態確認

```powershell
Get-Service -Name MyTunnelService | Format-Table Name, Status, StartType
```

必要なら手動起動:

```powershell
Start-Service -Name MyTunnelService
```

### A.5-3. ログ確認

```powershell
Get-ChildItem 'C:\ProgramData\MyTunnelApp\logs' | Sort-Object LastWriteTime -Descending
```

### A.5-4. イベントログ確認（致命的エラー時）

```powershell
Get-WinEvent -LogName Application -MaxEvents 200 |
  Where-Object { $_.ProviderName -eq 'MyTunnelService' } |
  Select-Object TimeCreated, LevelDisplayName, Message -First 20
```

## A.6. 参考: ローカル設定ファイルを使う場合（Windows VM）

通常はレジストリ (`HKLM\SOFTWARE\MyTunnelApp\ServerUrl` と互換用の `ConfigURL`) の値が優先されます。
`C:\ProgramData\MyTunnelApp\config.json` は不足項目を補完するために使えますが、`enrollment_secret` は平文になるためローカル検証用途に限定してください。

```powershell
@'
{
  "server_url": "http://<SCEP_SERVER_IP>:3000/scep",
  "client_uid": "client-001",
  "enrollment_secret": "one-time-secret",
  "device_id": "device-001",
  "poll_interval": "1h",
  "renew_before": "14d",
  "log_level": "info"
}
'@ | Set-Content -Path 'C:\ProgramData\MyTunnelApp\config.json' -Encoding UTF8
```

## B.Preregistration + Attestation E2E の実行

利用スクリプト:
- [`scripts/test/preregister_client.sh`](scripts/test/preregister_client.sh)
- [`scripts/linux/preregister_client_via_startup.sh`](scripts/linux/preregister_client_via_startup.sh)
- [`scripts/test/attestation_e2e.sh`](scripts/test/attestation_e2e.sh)
- [`scripts/test/attestation_e2e_canonical.sh`](scripts/test/attestation_e2e_canonical.sh)
- [`scripts/test/generate_device_id.sh`](scripts/test/generate_device_id.sh)

legacy helper (`test-nonce-key-binding-v1`) の実行例:

```bash
cd infra/terraform/scripts/test
SERVER_BASE_URL="http://${SERVER_IP}:3000"

TEST_UID="device-user-01"
SECRET='<strong-secret>'
./preregister_client.sh --server-base-url "$SERVER_BASE_URL" --uid "$TEST_UID" --secret "$SECRET" > prereg.out

./attestation_e2e.sh \
  --server-base-url "$SERVER_BASE_URL" \
  --prereg-output prereg.out
```

canonical helper (`tpm2-windows-v1`) の実行例:

```bash
cd infra/terraform/scripts/test
SERVER_BASE_URL="http://${SERVER_IP}:3000"

TEST_UID="device-user-02"
SECRET='<strong-secret>'
./preregister_client.sh --server-base-url "$SERVER_BASE_URL" --uid "$TEST_UID" --secret "$SECRET" > prereg-canonical.out

./attestation_e2e_canonical.sh \
  --server-base-url "$SERVER_BASE_URL" \
  --prereg-output prereg-canonical.out
```

オペレーター端末から `:3000` へ届かない場合は、server VM 側で localhost 実行する helper を使えます。

```bash
cd <this-repo>
./infra/terraform/scripts/linux/preregister_client_via_startup.sh \
  --uid "client-001" \
  --secret "one-time-secret" \
  --device-id "device-001"
```

期待結果:
- legacy helper:
  - 成功ケース: `success_matching_device_id`
  - 失敗ケース: `failure_mismatched_device_id`, `failure_invalid_attestation`
- canonical helper:
  - 成功ケース: `success_matching_device_id`
  - 失敗ケース: `failure_mismatched_device_id`, `failure_invalid_quote_signature`
- 生成物: `scripts/test/artifacts/...`

確認ポイント:
- `summary.txt` に `success_case=success_matching_device_id` が記録されること
- `success_matching_device_id/cert.pem` が生成され、`failure_*` ケースでは `exit_code.txt` が非 0 になること
- `attestation_e2e_canonical.sh` は current server verifier semantics を検証するため、OpenSSL-generated RSA AIK と synthetic quote/signature を使って canonical `tpm2-windows-v1` payload を組み立てる。Windows TPM hardware 由来の real attestation ではないため、Windows client rollout 検証とは別に扱うこと

### Real Windows canonical renewal validation

live GCP 上の Windows VM で real canonical attestation renewal まで確認したい場合は、committed harness `windows_canonical_renewal_e2e.sh` を使います。

```bash
cd <this-repo>/infra/terraform/scripts/test

WINDOWS_USER="<reset-windows-passwordで取得したユーザー名>"
./windows_canonical_renewal_e2e.sh \
  --windows-user "$WINDOWS_USER" \
  --client-uid "msi-stable-20260318051422" \
  --enrollment-secret "renewal-placeholder" \
  --device-id-override "device-20260318051422"
```

補足:

- `--server-url` を省略した場合、この harness は Terraform 出力の `server_internal_ip` から `http://<server_internal_ip>:3000/scep` を自動選択する。GCP 検証では Windows VM と server VM が同一 VPC にいるため、internal URL を既定とする
- harness は `build_windows_msi.sh` / `install_windows_msi.sh` を再利用し、silent reinstall 後に managed `cert.pem` と `LocalMachine\My` の thumbprint 変化を確認する
- renewal harness は引き続き `--apply-registry-overrides` を使う。これは「reconfiguration を通す」ためではなく、「same-version reinstall のまま current-run renewal を強制観測する」ための validation wiring である
- 成功時は JSON で `before_thumbprint`, `after_thumbprint`, `service_state`, `present_in_machine_store` を出力する

同じ MSI version への reinstall で advanced property を変えたい場合の補足:

- live GCP では raw `REINSTALL=ALL REINSTALLMODE=vomus` 付きの same-version reinstall でも requested config が旧 registry 値に負けることを再現した
- `install_windows_msi.sh` / `install-mytunnelapp.ps1` はこの stale-config 状態を検出すると、自動で uninstall → install の fresh-install path へ fallback する
- latest live verification run `copilot-install-20260324T081949Z-29988` では initial reinstall registry が `19s` / `7000h` / `info` のまま残ったことを検出し、その後 fallback path により final registry を `23s` / `6000h` / `error` へ更新できた。`service_state=Running`, `present_in_machine_store=true`, `reconfigure_fallback_used=true` を確認した
- issued certificate と TPM-backed key は uninstall 時にも残す方針なので、same-version reconfiguration の正式な operational path はこの fresh-install fallback である

## クリーンアップ（`terraform destroy`）とコスト注意

作業後は不要リソースを破棄してください。

```bash
cd infra/terraform
terraform destroy -var-file=terraform.tfvars
```

推奨クリーンアップ:
- 共有端末では機密を含むローカル成果物（`terraform.tfvars`, `prereg.out`, attestation artifacts）を削除
- 一時成果物（`tfplan`、ローカルビルド成果物）を削除

コスト注意:
- 主コストは Compute Engine VM（Linux + Windows）、永続ディスク、ネットワーク Egress
- パブリック IP 付き稼働 VM と Windows ライセンスでコストが増えます
- 検証時間を短くし、終了後すぐ破棄してください

## トラブルシューティング

### 1) Firewall / 接続性

- 症状: `:3000`, `:22`, `:3389` に接続できない
- `variables.tf` / `main.tf` の `scep_source_ranges`, `ssh_source_ranges`, `rdp_source_ranges` と VM タグを確認
- 自端末 IP が許可 CIDR に含まれているか確認

### 2) Firewall を開けても `Could not connect to server`

- 症状: `:3000` への curl が `Could not connect to server`
- サーバー VM での確認:
  ```bash
  gcloud compute ssh scep-server-vm --zone <ZONE> --project <PROJECT_ID> --command 'sudo systemctl status scep-server --no-pager'
  gcloud compute ssh scep-server-vm --zone <ZONE> --project <PROJECT_ID> --command "sudo ss -lntp | grep ':3000' || true"
  ```
- SCP 配備ステップを再実行:
  ```bash
  ./scripts/linux/build_and_scp_scepserver.sh
  ```
  （`terraform apply` 後の Terraform 出力が必要。必要に応じて `--terraform-dir` と各種 override を指定）
- 必要ならリモートヘルパーを直接実行:
  ```bash
  gcloud compute ssh <SERVER_INSTANCE_NAME> --zone <ZONE> --project <PROJECT_ID> --command 'sudo /usr/local/bin/deploy-scepserver-binary.sh /tmp/scepserver-opt'
  ```
- 再確認:
  ```bash
  curl -fsS "http://<SERVER_EXTERNAL_IP>:3000/admin/api/ping"
  ```

### 3) MySQL 認証 / DSN エラー

- 症状: `scep-server` サービスが起動直後に停止、または DB 認証エラー
- `mysql_user`, `mysql_password`, `mysql_database`, `scep_dsn`（任意上書き）を確認
- `mysql_password` に単一引用符 `'` を含める場合は SQL/起動処理のエスケープを見直す

### 4) Windows 起動スクリプト関連

- 症状: Windows クライアントに期待したサービスやバイナリが存在しない
- `scripts/windows/windows-client-startup.ps1` は準備処理（ディレクトリ/プレースホルダー/TODO ファイル作成）までで、製品バイナリのインストールや常駐起動は行いません
- `C:\scep-client\logs\startup-status.txt`、`C:\scep-client\runtime\artifact-acquisition.todo.ps1`、`C:\scep-client\runtime\invoke-client.todo.ps1` を確認し、本 README の「テスト時: Windows 側を手動で実行する手順」に沿って手動実行してください
