# Windows Client Certificate MSI Implementation Plan

## Goal

既存の SCEP 発行フローは維持したまま、Windows 向け MSI インストーラーを配布し、インストールされた Windows Service が TPM 保護鍵を用いてクライアント証明書を自動取得・自動更新できる状態を実現する。

この計画は、既存実装をそのまま踏襲することを前提にしない。ただし、すでに存在する `device_id` / `attestation` の通し口、Rust 製 Windows Service 雛形、Terraform による GCP 検証環境は再利用候補として扱う。

## Scope

- Windows MSI の対話 UI とサイレントインストール対応
- Windows Service による初回発行と自動更新
- TPM 保護鍵生成と attestation bundle 送信
- SCEP サーバー側のデバイス照合と TPM 検証
- GCP 上の SCEP サーバー + Windows VM による検証
- Terraform 管理下での再現可能な検証手順

## Non-Goals

- 既存の通常 SCEP クライアントの廃止
- 既存の WebUI / REST API 全面刷新
- 初期段階での多テナント対応や MDM 連携
- 初期段階でのオフライン登録フロー

## Terms

### TPM

TPM は秘密鍵を OS から直接抜き出せない形で保持できるセキュリティチップ、またはその仮想実装。GCP の Windows VM では物理 TPM ではなく `vTPM` を使う。

### CNG / KSP

Windows で TPM 保護鍵を扱うときは、TPM を直接たたくより、通常は CNG API と TPM 対応 KSP を経由する。要件の「TPM 内でキーペアを作る」は、実装上は「TPM-backed key を Windows の鍵ストアに生成する」と読み替える。

### Attestation Bundle

要件上は「TPM Attestation Statement」と表現されているが、Windows / TPM では単一の標準文字列ではなく、AIK、quote、PCR 値、nonce、EK 証明書など複数要素の束になることが多い。本計画ではこれを `attestation bundle` と呼ぶ。

### AIK

Attestation Identity Key。TPM が生成する署名用鍵で、quote への署名に使う。

### Quote

TPM が PCR 値と nonce をまとめて署名した証跡。サーバーはこれを検証して、送信側が TPM を持ち、かつ要求に対応する nonce を使ったことを確認する。

### PCR

Platform Configuration Register。起動状態などを表す TPM レジスタ。初期段階では PCR の厳密ポリシー評価まで広げすぎず、「署名検証が通ること」と「nonce が一致すること」を優先する。

## Design Principles

- 既存 SCEP の challenge / secret フローは壊さない
- TPM 検証は段階導入し、最初から過剰な信頼モデルを背負い込まない
- ユーザー入力は最小化し、同じ項目を UI と CLI の両方で指定できるようにする
- サービスは idempotent にし、再起動や更新で壊れにくくする
- 秘密情報は平文で残さず、Windows 側では DPAPI Machine Scope を第一候補にする
- テストは GCP 上で再現可能にする

## Current Reusable Assets

- サーバー側に `attestation` クエリパラメータの通し口がある
- サーバー側に `device_id` を属性として照合する雛形がある
- Rust の Windows Service 雛形がある
- WiX ベースの MSI 雛形がある
- Terraform で Linux SCEP サーバー VM と Windows VM を作成できる
- GCP Windows VM は `enable_vtpm = true` になっている
- `infra/terraform/scripts/test` に preregistration / attestation の検証スクリプトがある

## Target Architecture

1. 管理者がサーバー側でクライアントを登録する
2. クライアント登録情報に `device_id` を保持する
3. ユーザーが MSI を実行し、最小限の値を入力する
4. MSI は Windows Service と設定ファイルを配置し、サービスを登録する
5. サービスは初回起動時に TPM-backed key を生成し、CSR と attestation bundle を作る
6. サービスは SCEP の `PKIOperation` POST 時に `attestation` クエリパラメータへ bundle を載せる
7. SCEP サーバーは既存の challenge 検証に加えて `device_id` と TPM 署名検証を実施する
8. 検証成功時だけクライアント証明書を返す
9. サービスは期限監視を行い、更新期間に入ったら同じ手順で自動更新する

## Installer UX

前提:

- `device_id` はサーバー側で事前登録済みであることを前提にする

### Required Inputs

- `SERVER_URL`: SCEP サーバー URL
- `CLIENT_UID`: サーバーに登録済みのクライアント識別子
- `ENROLLMENT_SECRET`: 初回発行用 secret

### Optional Inputs

- `DEVICE_ID_OVERRIDE`: テスト用。通常は自動生成するため UI では非表示でもよい
- `POLL_INTERVAL`: 更新確認間隔
- `LOG_LEVEL`: トラブルシュート用

### UI Policy

- GUI では必須 3 項目だけを基本表示する
- `詳細設定` を開いたときのみオプション項目を表示する
- サイレントインストールでは同じ値を `msiexec` プロパティで渡せるようにする

### Silent Install Example

```powershell
msiexec /i scep-client.msi \
  SERVER_URL="https://scep.example.com/scep" \
  CLIENT_UID="client-001" \
  ENROLLMENT_SECRET="one-time-secret" \
  /qn /norestart
```

## Key Design Decisions

### 1. Device Identifier Source

`device_id` は手入力を前提にせず、次の優先順位で決める。

1. `DEVICE_ID_OVERRIDE` が指定されていればそれを使う
2. TPM EK public または AIK public のハッシュ
3. 上記が難しい場合のみ `ComputerName + BIOS Serial` の正規化値

理由:

- 人手入力の `device_id` は誤入力に弱い
- TPM に紐づく識別子のほうが、なりすまし耐性が高い
- ただし実装難度が高いため、フェーズ 1 ではフォールバックを許容する

運用方針:

- `device_id` はインストール前に管理者がサーバーへ事前登録しておく
- インストーラーは後追い登録フローを持たない
- `DEVICE_ID_OVERRIDE` は検証用途に限って残す

### 2. Attestation Payload Format

既存サーバー実装は base64url エンコード済み JSON を `attestation` クエリパラメータで受けられるため、初期段階ではこの形式を採用する。

nonce 方針:

- 初期実装からサーバー払い出し nonce を優先する
- attestation 生成前にクライアントが nonce を取得し、quote に含める
- secret や時刻窓からの暫定 nonce 導出は第一候補にしない
- nonce 取得は専用 REST API を追加して実現する

推奨 JSON フィールド:

```json
{
  "device_id": "...",
  "key": {
    "algorithm": "rsa-2048",
    "provider": "Microsoft Platform Crypto Provider",
    "public_key_spki_b64": "..."
  },
  "attestation": {
    "format": "tpm2-windows-v1",
    "nonce": "...",
    "aik_public_b64": "...",
    "quote_b64": "...",
    "quote_signature_b64": "...",
    "pcrs": [...],
    "ek_cert_b64": "..."
  },
  "meta": {
    "hostname": "...",
    "os_version": "...",
    "generated_at": "..."
  }
}
```

### 3. CSR Binding

サーバーは「attestation された公開鍵」と「CSR の公開鍵」が一致することを必ず確認する。これがないと、正しい TPM quote を別鍵の CSR に流用されうる。

### 4. Renewal Model

更新時も新規発行時と同じく attestation を取り直す。初期実装では同一鍵を継続利用し、再鍵生成は将来オプションにする。理由は、まず運用を単純化しつつ、TPM 鍵の継続使用確認と端末複製時の検知精度を維持するため。

更新認可方針:

- 初回発行後の自動更新認可は、既存クライアント証明書ベースで行う
- 初回発行用 enrollment secret は更新には使わない
- 更新用の別トークンは初期実装では導入しない

### 5. Windows Service Account

第一候補は `LocalService`。TPM-backed key と機械スコープの秘密保存に必要な権限が不足する場合のみ `LocalSystem` を検討する。

用語補足:

- `LocalService`: 権限の弱い組み込みアカウント
- `LocalSystem`: 権限の非常に強い組み込みアカウント

初期段階から `LocalSystem` に寄せると検証は楽だが、運用リスクが増えるため避ける。

## Workstreams

### A. Server Data Model and Admin API

目的: クライアント登録時に `device_id` を扱えるようにし、既存 challenge フローと共存させる。

実装項目:

- クライアント属性として `device_id` を正式サポートする
- Windows MSI 管理対象クライアントでは `device_id` を必須にする
- 管理 API / WebUI / CLI で `device_id` を登録・更新可能にする
- `device_id` の正規化ルールを定義する

受け入れ条件:

- 従来クライアントの既存フローを壊さず、Windows MSI 管理対象クライアントでは `device_id` ありが必須になる
- `device_id` 更新時のバリデーションが一貫する

### B. Windows Agent / Service

目的: TPM-backed key の生成、CSR 作成、SCEP 発行、自動更新をサービス化する。

実装項目:

- Rust サービス本体に状態機械を実装する
- 設定ロード元を MSI プロパティと設定ファイルに整理する
- 初回発行、期限監視、更新、エラーリトライを実装する
- 証明書格納先は Windows Machine Store を第一候補として実装する
- ログを Event Log + ファイルへ出す
- enrollment secret は DPAPI Machine Scope で保護して保存する

運用方針:

- 初回発行成功後、enrollment secret は Windows 側から削除する
- 自動更新は既存証明書と同一 TPM-backed key を用いて実施する
- 更新に追加認証が必要になった場合は別フローを設計し、初回用 secret の使い回しはしない

推奨状態:

- `NotConfigured`
- `WaitingForEnrollment`
- `GeneratingKey`
- `SubmittingCSR`
- `Issued`
- `RenewalDue`
- `ErrorBackoff`

### C. TPM Key and Attestation

目的: サービスが TPM-backed key と attestation bundle を生成できるようにする。

実装項目:

- Windows の CNG / NCrypt を使って TPM-backed key を生成する
- CSR の公開鍵と同一の鍵を attestation bundle に結びつける
- nonce をサーバーから取得するか、challenge から導出するかを決める
- attestation bundle を JSON 化し、base64url 化する

技術判断:

- 可能なら nonce はサーバー払い出しにする
- ただし SCEP の既存フローを大きく変えたくない場合、初期段階では secret と時刻窓を使った暫定 nonce でもよい

注意:

- Windows での TPM attestation は API 調査コストが高い
- フェーズ 1 で完全な PCR ポリシー検証まで入れず、まずは `TPM-backed key の生成 + attested key と CSR key の一致 + quote の署名検証` を成立させる

### D. SCEP Server Verification

目的: 受信した attestation bundle を検証し、登録済みデバイスだけへ証明書を発行する。

実装項目:

- `attestation` JSON スキーマを定義する
- base64url decode 後の JSON バリデーションを厳密化する
- `device_id` と登録情報を照合する
- quote 署名、nonce、公開鍵一致を検証する
- 失敗理由を監査ログへ残す

フェーズ 2 の必須ライン:

- quote 署名検証
- nonce 一致確認
- attestation 公開鍵と CSR 公開鍵の一致確認

初期段階では PCR 値ポリシー評価は必須にしない。

失敗分類:

- `missing_device_id`
- `device_id_mismatch`
- `invalid_attestation_format`
- `invalid_quote_signature`
- `nonce_mismatch`
- `public_key_mismatch`

### E. MSI Packaging

目的: GUI とサイレントインストールの両方を提供し、最小入力でサービスを構成できるようにする。

実装項目:

- WiX でインストーラー UI を追加する
- `SERVER_URL`, `CLIENT_UID`, `ENROLLMENT_SECRET` を受け取るダイアログを作る
- 入力値を安全に設定ファイルへ保存する
- サービス登録、アップグレード、アンインストールを整備する
- `msiexec` プロパティ名を UI 項目名と一致させる

注意:

- secret をレジストリ平文に置かない
- 更新後にサービス再登録が壊れないよう、UpgradeCode とサービス名を固定する
- アンインストール時、既定では証明書と鍵を残す
- 証明書や鍵の削除は明示オプションに分離する

### F. GCP Verification Environment

目的: Terraform で SCEP サーバー + Windows VM を再現し、E2E を検証できるようにする。

実装項目:

- 既存 Terraform に MSI 検証用の手順と変数を追加する
- Windows VM への MSI 転送は `gcloud compute scp` を第一候補として手順化する
- サイレントインストール検証用 PowerShell を追加する
- 発行成功と更新成功を確認する手順を README に追加する

前提:

- `gcloud auth login`
- `gcloud auth application-default login`

備考:

Terraform provider 認証は ADC のみをサポート対象とし、既存の `credentials_file` 方式は削除する。

## Recommended Phases

### Phase 0: Specification Freeze

- attestation JSON スキーマ確定
- `device_id` 生成ルール確定
- MSI 入力項目確定
- 鍵保管先と秘密保存方式確定

完了条件:

- サーバー・クライアント・インストーラーで同じ語彙を使えている

### Phase 1: Minimal End-to-End

目的: まず動く一本線を通す。

- サーバーに `device_id` 検証を正式導入
- Windows Service が TPM-backed key を生成
- attestation bundle は暫定的に `device_id + public key fingerprint + minimal proof` でも可
- MSI の GUI / silent install を実装
- GCP Windows VM で初回発行成功まで確認

完了条件:

- GUI install で証明書が 1 回取れる
- サイレント install でも同じ動作をする

### Phase 2: Real TPM Attestation Verification

- AIK / quote / nonce / CSR key binding を本実装
- サーバーの quote 検証を追加
- 改ざんケースを統合テスト化

完了条件:

- 不一致 device_id
- 改ざん attestation
- 不一致公開鍵

これらをサーバーが拒否できる

### Phase 3: Renewal and Operability

- 自動更新
- バックオフ、監査ログ、イベントログ
- アップグレード / 再インストール / ロールバック確認

完了条件:

- 期限前更新が成功する
- サービス再起動後も状態を復元できる

## Detailed Task Breakdown

### Server

- クライアント登録 API の `device_id` 仕様を文書化
- nonce 発行用の専用 REST API を追加する
- `device_id` 正規化関数を共通化
- attestation verifier を JSON スキーマ対応に拡張
- CSR 公開鍵との一致検証を追加
- 監査ログ項目を追加
- 単体テストと transport テストを追加

### Rust Service

- 設定モデルを `server_url`, `client_uid`, `enrollment_secret`, `device_id`, `renew_before`, `poll_interval` に整理
- Windows Machine Store の `LocalMachine\\My` との連携を実装
- TPM-backed key 作成と CSR 作成を実装
- attestation 前に専用 REST API から nonce を取得する
- SCEP クライアント呼び出しを内包するか、既存 CLI をライブラリ化して再利用する
- 更新判定を実装
- enrollment secret の保存は DPAPI Machine Scope を使う
- Renewal は同一鍵利用を既定とし、将来の再鍵生成オプション追加余地を残す
- 初回発行成功後に enrollment secret を削除する
- 更新認可は既存クライアント証明書ベースで行う

### MSI

- WiX UI ダイアログ作成
- カスタムアクションで設定ファイル生成
- サービス登録と開始順序の固定
- アンインストール時の鍵・証明書削除ポリシー決定
- 既定アンインストールでは証明書と鍵を残し、削除は明示オプションでのみ行う

### Terraform / Validation

- Windows 検証手順を README に統合
- MSI 配布方法を明文化
- サイレントインストール用 PowerShell 追加
- 更新確認用の時短設定を追加

## Validation Plan

### Functional Cases

- 正常系: 登録済み `device_id` + 正しい attestation で初回発行成功
- 異常系: 未登録 `device_id`
- 異常系: 改ざんされた attestation JSON
- 異常系: attestation の公開鍵と CSR 公開鍵が不一致
- 正常系: 期限前に自動更新成功

### Installer Cases

- GUI で必須項目だけ入力してインストール成功
- `msiexec` サイレントインストール成功
- Upgrade install 成功
- Uninstall 成功

### Operational Cases

- Windows 再起動後にサービス自動再開
- SCEP サーバー停止時にバックオフして復旧後に再試行
- 既発行証明書がある状態で設定が壊れても証明書自体は残る

## Deliverables

- `.github/instructions` 配下の仕様・計画文書
- Windows Service 実装
- WiX MSI 実装
- TPM attestation 検証実装
- Terraform / README / 検証スクリプト更新
- E2E テスト証跡

## Resolved Decisions

- `device_id` は事前登録前提にし、インストーラーは後追い登録フローを持たない
- Terraform 認証は ADC 限定とし、`credentials_file` ベースの認証は廃止する
- enrollment secret 保存は DPAPI Machine Scope を第一候補にする
- 証明書格納先は Windows Machine Store の `LocalMachine\\My` を第一候補にする
- Renewal はまず同一鍵利用で実装し、再鍵生成は将来オプションにする
- attestation nonce はサーバー払い出しを第一候補にする
- nonce 取得は専用 REST API を追加して実現する
- 初回発行成功後、enrollment secret は Windows 側から削除する
- 自動更新の認可は既存クライアント証明書ベースを第一候補にする
- フェーズ 2 の TPM 検証必須ラインは署名検証、nonce 一致、CSR 鍵一致とする
- GCP 検証時の MSI 配布は `gcloud compute scp` を第一候補にする
- アンインストール時、既定では証明書と鍵を残す

## Current Implementation Status

最終更新日: 2026-03-17

この節は、現在の source code と GCP 検証環境の実測結果をまとめた引き継ぎ用スナップショットである。

このセッションの終了時点で、Terraform 管理下の検証環境は `terraform destroy -auto-approve -var-file=terraform.tfvars` により破棄済みである。次セッションでは GCP 検証を再開する前に、必ず `infra/terraform` で `terraform apply` から開始すること。

### Overall Verdict

- source code は計画書へかなり寄せ直されているが、GCP 上の Windows 実ランタイムはまだ完全には追随していない
- Linux 側の `scep-server-vm` は live 応答しており、SCEP endpoint と nonce endpoint は動作している
- Windows 側の deployed service は直近検証ではまだ file-based key path を踏んでおり、計画書どおりの TPM-backed 実装へ完全移行できていない
- same-key renewal は source 上でも未完了であり、Phase 3 完了条件は未達
- TPM attestation は nonce と CSR 公開鍵 binding までは実装済みだが、AIK / quote / quote signature の暗号学的検証は未完了

### Implemented In Source

#### Server

- `device_id` の正規化と登録時バリデーションを追加済み
- attestation nonce 専用 REST API を追加済み
- attestation JSON の decode と `device_id` 照合を追加済み
- attestation 側の公開鍵と CSR 公開鍵の一致確認を追加済み
- nonce の払い出しと one-time consume を追加済み
- transport / unit test を追加済み

現在の到達点:

- Phase 1 から Phase 2 への途中段階
- `missing_device_id`, `device_id_mismatch`, `invalid_attestation_format`, `nonce_mismatch`, `public_key_mismatch` 相当の判定は実装済み
- `invalid_quote_signature` は未実装

#### Rust Windows Service

- 設定モデルを `server_url`, `client_uid`, `enrollment_secret`, `device_id`, `poll_interval`, `renew_before`, `log_level` に整理済み
- レジストリ値から `EnrollmentSecretProtected` を読み、DPAPI Machine Scope へ移行する処理を実装済み
- サービス状態機械を実装済み
- server nonce API を使う initial / renewal 用 nonce fetch を実装済み
- Windows CNG / NCrypt を使う persisted key path を source に実装済み
- `LocalMachine\\My` への証明書 install と既存証明書 probe を source に実装済み
- Go helper `cmd/scepclient` は generic key path に対応済みで、Windows persisted key provider / name / public SPKI を受け取れる

現在の到達点:

- 初回発行の TPM/CNG 経路は source には入っている
- same-key renewal submit は source 上で helper 経由に接続済み
- renewal certificate replacement も source 上では接続済みだが、GCP 上の end-to-end 実測証跡は未取得

#### MSI / Packaging / Terraform Docs

- Terraform provider は ADC 限定へ移行済み
- Linux 側の MSI build / copy 手順を README に追記済み
- `installer/main.wxs` には GUI / silent install 方針と `LocalService` 前提を反映済み
- `installer/main.wixl.wxs` は `scepclient.exe` を含む silent-install 向け source として更新済み
- `build_windows_msi.sh` の既定 stage dir は `build/windows-msi` へ移行済みで、generated wixl 入力を source tree の installer 定義と分離済み
- `installer/main.wxs` は `scepclient.exe` を同梱し、GUI MSI でも service helper を欠かさない状態へ修正済み
- `wixl` の表現力制約で registry ACL 付与を silent MSI に同等実装できないため、`installer/main.wixl.wxs` の service account は GCP 検証用に一時的に `LocalSystem` を採用している

注意:

- Windows startup script は placeholder bootstrap のままであり、MSI / service 本体の最終実装ではない

### Verified On GCP

#### Terraform / VM State

- Terraform は `scep-server-vm` と `scep-client-vm` を作成する構成である
- Windows VM は `enable_vtpm = true`, `enable_secure_boot = true`, `enable_integrity_monitoring = true`
- live environment でも両 VM は `RUNNING` を確認済み
- ただし上記は destroy 前の最終確認結果であり、現時点では検証環境は破棄済みである

#### Server VM Runtime

- `http://<server_external_ip>:3000/admin/api/ping` は `pong` を返す
- `GetCACaps` は `Renewal`, `SHA-1`, `SHA-256`, `AES`, `DES3`, `SCEPStandard`, `POSTPKIOperation` を返す
- `POST /api/attestation/nonce` は live 環境で 200 を返し、nonce を払い出す

判断:

- Linux 側の remote SCEP server VM は少なくとも HTTP endpoint と nonce API の観点では稼働している
- journal / systemd の直接確認は SSH user 解決や認証状態の影響を受けるため、セッションによっては外形確認だけで代替している

#### Windows VM Runtime

直近の serial / probe ベース検証では以下を観測した。

- managed directory 配下に `key.pem` が存在していた
- service log に `Software RSA Key (managed file)` と出ていた
- service は `WaitingForEnrollment -> GeneratingKey -> SubmittingCSR -> ErrorBackoff` を反復していた
- log 文言上は TPM-backed key 準備をうたっているが、実際の SCEP submit はまだ managed file key 経路だった

判断:

- GCP Windows VM 上の deployed runtime は、source にある TPM/CNG persisted-key 実装へまだ切り替わっていない
- source と deployed VM の実体を混同しないこと

### Remaining Gaps Against This Plan

#### Phase 1 Gaps

- GCP Windows VM で、TPM-backed key を使った初回発行成功の実測証跡がまだ取れていない
- Windows startup script が placeholder のままで、Terraform だけで MSI / service 実装が再現される状態ではない
- GUI MSI と wixl-based silent MSI の実体が二重化しており、検証時にどちらを source of truth とするかを明示維持する必要がある
- silent MSI は `LocalSystem`、GUI MSI は `LocalService + ACL` という一時差分が残っている

#### Phase 2 Gaps

- AIK / quote / quote signature の実検証が未実装
- PCR policy 評価は未実装
- server 側の attestation verifier は現状、nonce と CSR 公開鍵 binding を主に見ている

#### Phase 3 Gaps

- same-key renewal の source 実装は接続済みだが、certificate-based renewal authorization を含む end-to-end 成功証跡は未取得
- renewal 後の certificate replacement も remote 実測での成功確認が未完了
- 実 certificate ベースの renewal authorization 完了証跡が未取得

### Recommended Next Actions

次セッションは以下の順で進めること。

1. `infra/terraform` で `terraform apply` を実行し、`scep-server-vm` と `scep-client-vm` を再作成する
2. 新しい MSI / service binary を Windows VM に再配備し、deployed runtime が本当に TPM/CNG persisted-key 経路へ切り替わるかを再検証する
3. Windows VM 上で `key.pem` 非依存、`LocalMachine\\My` install、`Microsoft Platform Crypto Provider` 使用を実測で確認する
4. same-key renewal submission を実装し、renewal install path まで end-to-end でつなぐ
5. server 側に AIK / quote / quote signature 検証を追加し、Phase 2 の必須ラインを満たす
6. Terraform / README だけで再現できるよう、Windows startup script と MSI 配布手順の役割分担を整理する

### Session Handoff Notes

- 次セッションの GCP 検証は environment 作成から始めること。現時点で Terraform state は空であり、VM は残していない
- まず source code と deployed VM runtime を分けて考えること
- `scep-server-vm` は local server ではなく GCP 上の remote server を前提に検証すること
- Windows 側の最新実測では file-based key path が残っていたため、次セッションの最優先は「実装した persisted-key path が本当に配備されているか」の確認である
- generated wixl staging は `build/windows-msi` を見ること。`installer/` 配下の source と混同しないこと
- MySQL を要求する server test はローカル環境依存で失敗しうるため、GCP 検証とは分けて扱うこと

## Definition of Done

- GUI / サイレント install の両方で Windows Service を導入できる
- TPM-backed key を用いた初回発行が成功する
- SCEP サーバーが登録済み `device_id` と attestation を検証する
- 不正な attestation を拒否できる
- 自動更新が期限前に成功する
- GCP + Terraform の検証手順が README だけで再現できる
