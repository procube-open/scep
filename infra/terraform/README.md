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
- Windows MSI をローカルで作る場合は `cargo`, `rustup`, `x86_64-w64-mingw32-gcc` に加え、release packaging 用に `dotnet` + `wix` と Linux-host WiX 実行用の `wine` が必要です。`wixl` は開発用 fallback としてのみ扱います

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
   - current Terraform default は `scep-server-vm` を internal-only のままにし、`scep-client-vm` にだけ external IP を付けて operator RDP / CRD access に使います。`rdp_source_ranges` は必ず最小 CIDR に絞ってください
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
   SERVER_IP="$(terraform output -raw server_internal_ip)"
   curl -fsS "http://${SERVER_IP}:3000/admin/api/ping"
   ```

`outputs.tf` で主に使う出力:
- `server_instance_name`, `client_instance_name`
- `deployment_zone`, `project_id`
- `server_internal_ip`, `client_internal_ip`
- `server_external_ip`, `client_external_ip`（current default では `server_external_ip` は空文字、`client_external_ip` は operator access 用に値を持ちます）

## サーバーブートストラップ確認

`terraform apply` と SCP 配備後に以下を確認します。

1. 許可済み送信元から SCEP エンドポイントを確認:
   ```bash
   SERVER_IP="$(terraform output -raw server_internal_ip)"
   curl -fsS "http://${SERVER_IP}:3000/admin/api/ping"
   curl -fsS "http://${SERVER_IP}:3000/scep?operation=GetCACaps"
   ```
   手元端末から直接 curl できない internal-only 構成では、同一 VPC 内の VM か踏み台 / VPN / IAP 経由で確認します。
2. Linux VM サービス状態を確認:
   ```bash
   gcloud compute ssh scep-server-vm --zone <ZONE> --project <PROJECT_ID> --command 'sudo systemctl status mysql scep-server --no-pager'
   ```
3. ブートストラップ異常時は起動ログを確認:
   - `gcloud compute instances get-serial-port-output`
   - `/var/log/syslog`
   - `journalctl -u scep-server -u mysql --no-pager`

## windows クライアント

通常の自動検証 / helper 実行は internal URL + startup-script / serial 経由を標準とし、人手で GUI を触る場合のみ Chrome Remote Desktop / RDP を使います。以下では GUI 主経路 (A) と、検証 automation 用 helper 経路 (B) を記述します。

## A.1. 接続情報の取得（手元端末）

```bash
cd infra/terraform
CLIENT_INSTANCE="$(terraform output -raw client_instance_name)"
CLIENT_IP="$(terraform output -raw client_internal_ip)"
CLIENT_PUBLIC_IP="$(terraform output -raw client_external_ip)"
ZONE="$(terraform output -raw deployment_zone)"
PROJECT_ID="$(terraform output -raw project_id)"
SERVER_IP="$(terraform output -raw server_internal_ip)"
```

## A.2. Windows ログイン情報の取得（手元端末）

```bash
gcloud compute reset-windows-password "$CLIENT_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID"
```

current Terraform default では `scep-server-vm` は internal-only のままにし、`scep-client-vm` にだけ external IP を付けます。GUI 操作が必要な場合は `CLIENT_PUBLIC_IP` へ RDP 接続するか、同じ外部 IP を使って Chrome Remote Desktop bootstrap 後の operator access に使ってください。SCEP / prereg / renewal の通信先は引き続き internal `SERVER_IP` を優先します。

Chrome Remote Desktop の one-time support code は headless / CLI では生成できません。repo には host bootstrap 用 helper として `infra/terraform/scripts/linux/prepare_windows_chrome_remote_desktop.sh` を追加しており、これは Windows VM に Chrome Remote Desktop Host を入れ、Edge があればそれを再利用し、必要なら Chrome も入れたうえで、**次回の interactive logon で** `https://remotedesktop.google.com/support` を自動表示するためのものです。実際の access code 生成は、その browser session で Google に sign in して `Generate Code` を押してください。

```bash
./infra/terraform/scripts/linux/prepare_windows_chrome_remote_desktop.sh
gcloud compute reset-windows-password "$CLIENT_INSTANCE" --zone "$ZONE" --project "$PROJECT_ID"
```

## A.3. テスト時のみ: Linux 手元端末で MSI をローカル作成し、必要なら Windows VM へ転送

> 本番環境では MSI 配布は別途実施してください。以下は検証用途のみです。Windows 側の操作を最小化するため、MSI の生成は Linux 手元端末で完結させます。

1. Linux の手元端末で必要な依存を入れます。

```bash
cd <this-repo>
sudo apt-get update
sudo apt-get install -y gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64 msitools wine
rustup target add x86_64-pc-windows-gnu
dotnet tool install --global wix
```

`build_windows_msi.sh` の supported release path は WiX v4 (`installer/main.wxs`) です。Linux host では `wix` CLI と `wine` を使ってこの path を実行します。
`wixl` (`installer/main.wixl.wxs`) は比較・開発用 fallback としてのみ残しており、release の同等保証対象にはしません。

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
- `build/windows-msi` への installer 入力ステージング
- `installer/main.wxs` を WiX v4 path でビルドして GUI 付き MSI を生成
- 必要時のみ `installer/main.wixl.wxs` で開発用 fallback MSI を生成
- `build/windows-msi/installer/dist/MyTunnelApp.msi` の生成

release 検証では `--msi-builder wix` を使ってください。`--msi-builder auto|wix|wixl` は比較や切り分け用に明示できます。

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

最終的なエンドユーザー向け方針は、Windows ユーザーが **MSI をダブルクリックし、必要な値を GUI で入力してインストールを完了する** ことです。
この方針自体は現在も `installer/main.wxs` に反映されており、WiX v4 (`wix`) でビルドした MSI には GUI ダイアログが含まれます。

一方で、ローカル Linux ビルドは `wix` があれば `installer/main.wxs` を使う converged package を優先し、無ければ `wixl` ベースの fallback MSI を生成します。
この README では、release blocker の primary evidence である **GUI 手順**と、後続 automation / comparison 用の **silent install 手順**の両方を記載します。

現時点の WiX v4-authored MSI でも、current GCP Windows / `vTPM` 制約のため、初回 TPM-backed bootstrap が成立する validated default は `LocalSystem` です。
`LocalService` 収束は hardening 用の optional helper path (`install_windows_msi.sh --converge-to-local-service`) として扱います。
また `wixl` fallback では WiX v4 側のような registry ACL 付与を同等に表現できないため、fallback MSI も引き続き `LocalSystem` authored state です。
2026-03-25 の local probe でも `wixl` は `RegistryKey/Permission` と `Component/RemoveRegistryKey` を `unhandled child` として reject したため、fallback MSI は uninstall cleanup semantics も GUI MSI とまだ揃っていません。
release の supported packaging は WiX v4 のみであり、`wixl` fallback は比較・開発用途に留めます。

### A.4-1. GUI インストール（WiX v4 でビルドした MSI）

この手順は、**WiX v4 でビルドされた GUI 付き MSI** を前提にします。ユーザー体験としては、Windows 上で MSI をダブルクリックして通常のインストーラー画面を進める形です。

1. `MyTunnelApp.msi` をダブルクリックします。
2. 通常のインストーラー画面を進めると、SCEP 設定入力ダイアログが表示されます。
3. **Step 1** で MSI 自身が Windows TPM endorsement key から canonical `CURRENT_DEVICE_ID` を probe します。表示された値を管理者がサーバーへ preregister します。
4. **Step 2** で次を入力し、**Check** または **Next** で prereg-check を実行します。
   - `SERVER_URL`: **SCEP サーバーの URL**。証明書発行要求と prereg-check を送る宛先です。
   - `CLIENT_UID`: **サーバー側に事前登録済みの opaque client identifier** です。
5. prereg-check が `ready` になったら **Step 3** で `ENROLLMENT_SECRET` を入力します。これは **初回発行だけに使うワンタイム秘密値**です。
6. 必要なら **Advanced...** を開き、次を確認または入力します。
   - `EXPECTED_DEVICE_ID`: **Step 1 で probe された canonical TPM identity** です。release build では MSI が自動設定し、手入力 override は受け付けません。
   - `POLL_INTERVAL`: **更新確認の間隔**です。省略時は既定値を使えます。
   - `RENEW_BEFORE`: **証明書期限のどれくらい前から更新を試みるか**を表す値です。省略時は既定値を使えます。
   - `LOG_LEVEL`: **ログの詳細度**です。通常は既定値のままで構いません。
7. **Install** を押してインストールを完了します。

補足:

- GUI MSI は page 1 で canonical TPM identity を自動 probe し、page 2 で `/api/attestation/prereg-check` を叩いて `ready | client_not_found | device_id_mismatch | not_issuable_yet` を確認します。
- GCP 検証環境で Windows VM から server VM へ到達させる場合、`SERVER_URL` は通常 `http://<server_internal_ip>:3000/scep` を使います。**`server_internal_ip`** は、Terraform が出力する **同一 VPC 内の内部 IP アドレス**です。
- release blocker の primary issuance evidence は、この GUI flow を GCP Windows VM 上で実際に通した記録です。

### A.4-2. サイレントインストール

まず canonical TPM identity を確認します。`build_windows_msi.sh --windows-user ...` は `device-id-probe.exe` も一緒に Windows VM へ転送し、別 helper `probe_windows_device_id.sh` で JSON を取得できます。

```bash
cd <this-repo>
./infra/terraform/scripts/linux/probe_windows_device_id.sh \
  --windows-user "<reset-windows-passwordで取得したユーザー名>"
```

出力 JSON の `expected_device_id` を preregistration し、その値を silent install 時の `EXPECTED_DEVICE_ID` に使います。

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
    "EXPECTED_DEVICE_ID=`"<probe_windows_device_id.sh で得た expected_device_id>`"",
    "POLL_INTERVAL=`"1h`"",
    "RENEW_BEFORE=`"14d`"",
    "LOG_LEVEL=`"info`"",
    "/qn",
    "/norestart"
) -join ' '
Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -NoNewWindow
```

`SERVER_URL` は GCP 検証では Terraform 出力の `server_internal_ip` を優先して以下のように設定してください。

- 例: `http://<SERVER_INTERNAL_IP>:3000/scep`
- 互換用に MSI 内には旧 `SERVICE_URL` property も残していますが、この手順では `SERVER_URL=...` を指定してください。
- `EXPECTED_DEVICE_ID` は `device-id-probe.exe` / `probe_windows_device_id.sh` で得た canonical TPM identity と一致させてください。helper は install 前に prereg-check を実行し、`ready` でなければ fail fast します。

現状の MSI は non-secret 設定をレジストリへ保存し、`ENROLLMENT_SECRET` は bootstrap 用に短時間だけレジストリへステージングします。
サービスは必要に応じて DPAPI Machine Scope を経由して bootstrap secret を扱いますが、successful initial issuance 後は `EnrollmentSecret` / `EnrollmentSecretProtected` の両方を削除します。
WiX だけで直接 DPAPI 化しているわけではない点は現フェーズの制約です。
validated default は `LocalSystem` bootstrap のまま発行・更新を成立させることです。`install_windows_msi.sh --converge-to-local-service` は optional hardening / comparison 用 helper として残します。
また service は設定ロード時に `POLL_INTERVAL > RENEW_BEFORE` を warning として出し、証明書 validity が取れる場合は effective renewal timing を `min(RENEW_BEFORE, certificate_lifetime - POLL_INTERVAL)` へ clamp します。same-key renewal で古い証明書が `LocalMachine\My` に残る cleanup / retention は引き続き manual 運用です。

### A.4-3. Linux から startup-script 経由で silent install を走らせる（検証 automation 用）

Windows VM が OpenSSH を受け付けない場合は、ローカル Linux 端末から startup-script を一時差し替えて silent install を実行できます。これは GCP 検証 automation のための helper path であり、正式な導入主経路ではありません。
この helper は `terraform output` から `project_id`, `deployment_zone`, `client_instance_name` と server IP を自動解決し、`--server-url` を省略した場合は `server_internal_ip` を優先して使います。シリアルログには install / verify のマーカーを出しながら待機します。

```bash
cd infra/terraform
SERVER_IP="$(terraform output -raw server_internal_ip)"

cd <this-repo>
./infra/terraform/scripts/linux/install_windows_msi.sh \
  --client-uid "client-001" \
  --enrollment-secret "one-time-secret" \
  --expected-device-id "<probe_windows_device_id.sh で得た expected_device_id>"
```

補足:

- 既定では `C:\Users\Public\MyTunnelApp.msi` を install 対象にするため、先に `build_windows_msi.sh --windows-user ...` などで MSI を Windows VM へ転送しておいてください。
- `build_windows_msi.sh --windows-user ...` は `device-id-probe.exe` も同時に転送します。silent preregistration では `probe_windows_device_id.sh` を併用してください。
- `install_windows_msi.sh` / `install-mytunnelapp.ps1` は `device-id-probe.exe -json` で local TPM identity を再確認し、`/api/attestation/prereg-check` が `ready` でなければ `msiexec` 実行前に停止します。
- helper は一時的に enrollment secret を startup-script metadata へ埋め込みます。これは GCP 検証用の one-time secret 前提で使い、正式運用の配布経路にはしません。実行後は元の startup script へ戻します。
- シリアルログでは `MYTUNNEL_MSI_INSTALL_DONE` / `MYTUNNEL_MSI_INSTALL_FAILED` を確認できます。

## A.5. 動作確認（Windows VM / 管理者 PowerShell）

### A.5-1. レジストリ確認

```powershell
Get-ItemProperty -Path 'HKLM:\SOFTWARE\MyTunnelApp' -Name ServerUrl,ConfigURL,ClientUid,ExpectedDeviceId,DeviceId,PollInterval,RenewBefore,LogLevel,EnrollmentSecret,EnrollmentSecretProtected -ErrorAction SilentlyContinue
```

current validated path では、初回発行成功後に `EnrollmentSecret` / `EnrollmentSecretProtected` の両方が absent になっていることを確認してください。

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
  "expected_device_id": "device-001",
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
- [`scripts/linux/probe_windows_device_id.sh`](scripts/linux/probe_windows_device_id.sh)
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

Windows MSI 管理対象 client を事前登録したい場合は、`preregister_client.sh` に `--managed-client-type windows-msi` を追加します。`windows-msi` は `device_id` 必須かつ credential activation 必須を意味します。

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
  --expected-device-id "device-20260318051422"
```

補足:

- `--server-url` を省略した場合、この harness は Terraform 出力の `server_internal_ip` から `http://<server_internal_ip>:3000/scep` を自動選択する。GCP 検証では Windows VM と server VM が同一 VPC にいるため、internal URL を既定とする
- harness は `build_windows_msi.sh` / `install_windows_msi.sh` を再利用し、silent reinstall 後に managed `cert.pem` と `LocalMachine\My` の thumbprint 変化を確認する
- current policy では same-key renewal は既存証明書ベースで認可するため、この harness では `--enrollment-secret` を省略できる。fresh issuance / `--force-fresh-install` を伴う run では引き続き初回用 secret が必要
- renewal harness は引き続き `--apply-registry-overrides` を使う。これは「reconfiguration を通す」ためではなく、「same-version reinstall のまま current-run renewal を強制観測する」ための validation wiring である
- current release-path validation は `LocalSystem` bootstrap のまま行う。`LocalService` 収束は lower-level `install_windows_msi.sh --converge-to-local-service` による optional hardening path として別途実施する
- 成功時は JSON で `before_thumbprint`, `after_thumbprint`, `service_state`, `present_in_machine_store` を出力する
- 2026-04-01 の current WiX v4 positive run `copilot-install-20260401T083450Z-7118` では `service.start_name=LocalSystem`, `managed_thumbprint=102D4FFFB0B660C2FAD3EFB21CBE09A5B36BFF8B`, `present_in_machine_store=true`, `has_enrollment_secret=false`, `has_enrollment_secret_protected=false` を確認した
- 2026-04-02 の secretless same-key renewal rerun `copilot-install-20260402T084540Z-30130` は、当初は thumbprint `931A82AA17DFD462E80F56A7B5646B18D4CBDF93 -> 03EF969DD79E377E59EB34DDC447BAC0C2814B76` の回転と `present_in_machine_store=true`, `service_state=Running` により成功に見えたが、後続の server-side truth probe で false positive と判明した。server の active cert は `4E8AFDAFA7829D4886702D1548A9B19CAA5BEE5F` のままで、local の `03EF969DD79E377E59EB34DDC447BAC0C2814B76` は server 上では revoked だったため、current validation は `after_thumbprint == server.active_thumbprint` を必須条件にし、helper も server-active cert が `LocalMachine\My` にない場合は別 cert へ同期しない
- 2026-04-06 の stale-binary rerun `copilot-install-20260406T044911Z-16810` では、same-version reinstall 後の `Program Files\MyTunnelApp\service.exe` hash mismatch を helper が検出し、`phase=binary-refresh-fallback reason=same-version reinstall left stale Program Files binaries: service.exe` を live GCP で確認した。これに合わせて helper は installed `service.exe` / `scepclient.exe` hash を summary に載せ、validation も `program_files_match_expected` を success 条件に追加した
- 2026-04-06 の recovery run `copilot-install-20260406T052948Z-24195` では、lower-level helper `install_windows_msi.sh --force-fresh-install --reuse-existing-certificate` を使って managed / server thumbprint を `03EF969DD79E377E59EB34DDC447BAC0C2814B76 -> 6AD16FAC53787DFECEDF712DFD3887D1AB725E72` へ回転させ、`program_files_match_expected=true`, `service_sha256=f76f99ff79ece806a4128ee4a4d4ec4d6dd765f8543218a1581a1b029ed3dfb7`, `managed_matches_server_active=true` を確認した
- 続く blank same-version renewal rerun `copilot-install-20260406T054903Z-30507` では `fresh_install_requested=false`, `reinstall_requested=true` のまま managed / server thumbprint を `DE4A40AC4C236316FE0D08899CD1F62441D56176 -> 36D1A895AC0C3F69FD300E5A0C45EC76CA66D8BA` へ回転させ、`program_files_match_expected=true`, `managed_matches_server_active=true`, `server_active_thumbprint_changed=true` を再確認した

2026-03-25 の live validation では、managed Windows client `msi-neg-20260325050312` を `preregister_client.sh --managed-client-type windows-msi` で登録したうえで Windows MSI を導入し、external `GET /api/client/msi-neg-20260325050312` が `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返すことを確認した。既存 activation client `msi-activation-20260325014801` についても managed `cert.pem` thumbprint=`539779D92B8EB0E463C0CC547E8819B7E6E0E212`, `has_enrollment_secret=false`, `service_state=Running` を継続確認した。

同日の fallback MSI runtime convergence validation では、`install_windows_msi.sh` の lower-level helper も `--server-url` 省略時に Terraform 出力の `server_internal_ip` を優先するよう更新したうえで、次を live 確認した。

- fresh install run `copilot-install-20260325T070546Z-17570` は client `msi-localsvc-ok-20260325070516` を `service.start_name=NT AUTHORITY\LocalService`, `present_in_machine_store=true`, `has_enrollment_secret=false`, `managed_thumbprint=29FF8482FBAEC855CAAC49B67F2ECF632295FC0E` で収束させ、external `GET /api/client/msi-localsvc-ok-20260325070516` でも `status=ISSUED`, `attributes.managed_client_type=windows-msi` を確認した
- same-version reinstall run `copilot-install-20260325T070729Z-4061` は同 client を `NT AUTHORITY\LocalService` のまま `29FF8482FBAEC855CAAC49B67F2ECF632295FC0E` から `CA46C3C29159BB0F8E9C6127705449814B819B3D` へ回転させ、`present_in_machine_store=true`, `managed_thumbprint_changed=true` を返した

同日の live negative check として、external `POST /api/attestation/activation/start` に対して以下を確認した。

- bogus nonce は `403 nonce mismatch`
- valid nonce に対する不正 `ek_public_b64` は `400 ek_public_b64 is not a valid SubjectPublicKeyInfo`

### Tampered activation proof negative validation

tampered `activation_proof_b64` renewal を確認したい場合は、committed helper `windows_activation_negative_renewal_e2e.sh` を使います。

```bash
cd <this-repo>/infra/terraform/scripts/test

WINDOWS_USER="<reset-windows-passwordで取得したユーザー名>"
./windows_activation_negative_renewal_e2e.sh \
  --windows-user "$WINDOWS_USER" \
  --client-uid "msi-neg-20260325050312" \
  --enrollment-secret "one-time-secret" \
  --expected-device-id "device-neg-20260325050312" \
  --force-fresh-install
```

補足:

- harness は `build_windows_msi.sh` / `install_windows_msi.sh --tamper-activation-proof-renewal` を再利用し、install 後に `scepclient.exe -emit-attestation` で real canonical attestation を組み立て、`activation_proof_b64` を改ざんした renewal を送る
- negative helper は `renewal_rejected=true`、managed certificate が `LocalMachine\\My` に残ること、managed thumbprint が変化しないことを満たした場合のみ成功として返る。`renewal_exit_code` は補助情報であり authoritative ではない
- 2026-04-02 の clean rerun `copilot-install-20260402T020037Z-12035` では client `wcneg_20260402T015627Z_f4c83785f8cf` に対して `activation_negative.renewal_exit_code=0`, `renewal_rejected=true`, `managed_thumbprint_before=managed_thumbprint_after=35BC281F065042D8CABE40750555370AF332E6EC`, `service.state=Running` を summary から確認した。live `scep-server-vm` journal でも `invalid attestation: invalid_activation_proof` を記録しており、negative 判定では `renewal_exit_code` ではなく `renewal_rejected` / `renewal_failure_excerpt` を authoritative に見る
- GCP Windows vTPM path では repeated reset に伴って guest agent が `TPM is in DA lockout mode` warning を出しうるため、harness rerun は間隔を空けて実施する

同じ MSI version への reinstall で advanced property を変えたい場合の補足:

- live GCP では raw `REINSTALL=ALL REINSTALLMODE=vomus` 付きの same-version reinstall でも requested config が旧 registry 値に負けることを再現した
- `install_windows_msi.sh` / `install-mytunnelapp.ps1` はこの stale-config 状態を検出すると、自動で uninstall → install の fresh-install path へ fallback する
- same-version reinstall が stale Program Files binary を残す場合、helper は local current build hash と installed `service.exe` / `scepclient.exe` hash を比較し、自動で binary-refresh fallback に切り替える
- uninstall 後に blank secret で existing managed cert を再利用する recovery が必要な場合、lower-level helper は `--reuse-existing-certificate` で minimal registry を seed し、MSI launch condition を満たしたまま force-fresh-install を通せる
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
