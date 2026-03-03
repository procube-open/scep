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
- Terraform Provider 用の Google 認証情報 JSON ファイル（`provider.tf` の `credentials = file(var.credentials_file)` で参照）
- `./scripts/linux/build_and_scp_scepserver.sh` を使う場合は `go` と `gcloud` が必要

### GCP 認証モデルと credentials ファイルの扱い

1. オペレーターとして `gcloud` にログインし、対象プロジェクトを設定します。
   ```bash
   gcloud auth login
   gcloud config set project <PROJECT_ID>
   ```
2. `terraform.tfvars` の `credentials_file` に、Terraform が参照する認証情報 JSON の絶対パスを設定します。
3. 可能な限り認証情報ファイルはリポジトリ外に置いてください。

### シークレット管理の注意（必須）

- 認証情報 JSON の中身をドキュメント、ログ保存対象のターミナル、Issue/PR コメントに貼り付けないでください。
- 認証情報ファイルや秘密値入り `terraform.tfvars` を Git にコミットしないでください。
- 機密ファイルは厳しい権限にしてください（例: `chmod 600 /path/to/service-account.json terraform.tfvars`）。
- 組織で利用可能なら長期固定キーより短命クレデンシャルや秘密情報管理基盤を優先してください。

## `terraform.tfvars` の準備

1. 変数ファイルを作成します。
   ```bash
   cd infra/terraform
   cp terraform.tfvars.example terraform.tfvars
   ```
2. 少なくとも以下を更新します。
   - `project_id`, `region`, `zone`
   - `credentials_file`（認証情報 JSON の絶対パス）
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
   **そのため `terraform apply` 実行済みで、`terraform output` が取得できる状態が前提です。**
   デフォルト構成外で使う場合は `--terraform-dir <PATH>` を指定し、必要に応じて `--project` / `--zone` / `--instance` で上書きしてください。
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

## A.3. テスト時のみ: Linux 手元端末でビルドし、MSI 作成素材を SCP 転送

> 本番環境では MSI 配布は別途実施してください。以下は検証用途のみです。

1. Linux の手元端末で `service.exe` をクロスビルドします。

```bash
cd <this-repo>
sudo apt-get update
sudo apt-get install -y gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64
rustup target add x86_64-pc-windows-gnu

cargo build --manifest-path rust-client/service/Cargo.toml --release --target x86_64-pc-windows-gnu
```

2. Windows 側で MSI 作成に必要なファイルをステージングします（`main.wxs` と `service.exe`）。

```bash
cd <this-repo>
STAGE_DIR="$(pwd)/installer/windows-msi"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/installer" "$STAGE_DIR/rust-client/service/target/release"

cp installer/main.wxs "$STAGE_DIR/installer/main.wxs"
cp rust-client/target/x86_64-pc-windows-gnu/release/service.exe \
  "$STAGE_DIR/rust-client/service/target/release/service.exe"
```

3. ステージングした素材を Windows VM に SCP 転送します。

```bash
WINDOWS_USER="<reset-windows-passwordで取得したユーザー名>"

gcloud compute scp --recurse "$STAGE_DIR" "${WINDOWS_USER}@${CLIENT_INSTANCE}:~/" \
  --zone "$ZONE" \
  --project "$PROJECT_ID"
```

4. RDP 接続後、Windows VM（PowerShell）で MSI を作成します。

```powershell
$MsiWorkDir = Join-Path $env:USERPROFILE 'windows-msi'

if (-not (Test-Path "$MsiWorkDir\installer\main.wxs")) {
  throw "main.wxs not found: $MsiWorkDir\installer\main.wxs"
}
if (-not (Test-Path "$MsiWorkDir\rust-client\service\target\release\service.exe")) {
  throw "service.exe not found: $MsiWorkDir\rust-client\service\target\release\service.exe"
}

if (-not (dotnet tool list --global | Select-String -SimpleMatch ' wix ')) {
  dotnet tool install --global wix
} else {
  dotnet tool update --global wix
}

$DotnetToolPath = "$env:USERPROFILE\.dotnet\tools"
if (-not (($env:PATH -split ';') -contains $DotnetToolPath)) {
  $env:PATH = "$env:PATH;$DotnetToolPath"
}

New-Item -ItemType Directory -Path "$MsiWorkDir\installer\dist" -Force | Out-Null
wix build "$MsiWorkDir\installer\main.wxs" -arch x64 -o "$MsiWorkDir\installer\dist\MyTunnelApp.msi"
Copy-Item "$MsiWorkDir\installer\dist\MyTunnelApp.msi" "$env:USERPROFILE\MyTunnelApp.msi" -Force
```

## A.4. インストールと起動（Windows VM / 管理者 PowerShell）

```powershell
$MsiPath = "$env:USERPROFILE\MyTunnelApp.msi"
$ServiceUrl = "http://<SCEP_SERVER_IP>:3000/scep"

if (-not (Test-Path $MsiPath)) {
  throw "MSI not found: $MsiPath"
}

New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null

$arguments = "/i `"$MsiPath`" SERVICE_URL=`"$ServiceUrl`" /qn /norestart"
Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -NoNewWindow
```

`SERVICE_URL` は Terraform 出力の `server_external_ip` を使って以下のように設定してください。

- 例: `http://<SERVER_IP>:3000/scep`

## A.5. 動作確認（Windows VM / 管理者 PowerShell）

### A.5-1. レジストリ確認

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\MyTunnelApp' -Name ConfigURL
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

通常はレジストリ (`HKLM\SOFTWARE\MyTunnelApp\ConfigURL`) が優先されます。  
レジストリ未設定時のフォールバックとして `C:\ProgramData\MyTunnelApp\config.json` を置けます。

```powershell
@'
{
  "config_url": "http://<SCEP_SERVER_IP>:3000/scep"
}
'@ | Set-Content -Path 'C:\ProgramData\MyTunnelApp\config.json' -Encoding UTF8
```

## B.Preregistration + Attestation E2E の実行

利用スクリプト:
- [`scripts/test/preregister_client.sh`](scripts/test/preregister_client.sh)
- [`scripts/test/attestation_e2e.sh`](scripts/test/attestation_e2e.sh)
- [`scripts/test/generate_device_id.sh`](scripts/test/generate_device_id.sh)

実行例:

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

期待結果:
- 成功ケース: `success_matching_device_id`
- 失敗ケース: `failure_mismatched_device_id`, `failure_invalid_attestation`
- 生成物: `scripts/test/artifacts/...`

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
