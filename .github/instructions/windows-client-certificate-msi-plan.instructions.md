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
- Windows 管理対象を示す明示属性 `managed_client_type` を導入し、`windows-msi` を正式値として扱う
- Windows MSI 管理対象クライアントでは `device_id` を必須にする
- 管理 API / WebUI / CLI で `device_id` を登録・更新可能にする
- 管理 API / WebUI / CLI で `managed_client_type=windows-msi` を `Windows MSI 管理対象` として露出する
- 既存 Windows 管理対象クライアントの移行は推定ではなく管理 API / スクリプトによる明示更新で行う
- `device_id` の正規化ルールを定義する

受け入れ条件:

- 従来クライアントの既存フローを壊さず、Windows MSI 管理対象クライアントでは `device_id` ありが必須になる
- `managed_client_type=windows-msi` の client は credential activation 必須として扱われる
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
- Windows 管理対象クライアントは明示属性 `managed_client_type=windows-msi` で識別する
- `managed_client_type=windows-msi` は credential activation 必須を意味し、既存の `attestation_activation_required` はこの属性へ置き換え済みとする
- 既存 Windows 管理対象 client の移行は server 側の自動推定ではなく、管理 API / スクリプトで明示更新する
- `managed_client_type=windows-msi` の add/update では `device_id` を必須にする
- WebUI / CLI では raw attribute 名ではなく `Windows MSI 管理対象` として露出する
- Windows TPM quote / credential activation の helper-backed 実装は当面の正式構成とし、Rust への全面移行は後続フェーズで再判断する

## Current Implementation Status

最終更新日: 2026-03-25

この節は、直近の source code と GCP 検証環境の実測結果をまとめた引き継ぎ用スナップショットである。今回の更新では、local source の credential activation round-trip 実装と、再起動した live GCP 上の `scep-client-vm` / `scep-server-vm` に対する positive / negative validation を統合している。検証環境そのものは引き続き Terraform 管理下にあるが、本日の作業終了時点では `scep-server-vm` と `scep-client-vm` を再度停止済みである。

### Overall Verdict

- local source には、Phase 2 の canonical server verifier に加えて、Windows 向け `cmd/scepclient` の real canonical attestation emission を追加済みである。helper は `go-attestation` を使う temporary `AK` と `go-tpm` 互換 wire format で `AIK public`, raw `AIK TPM public`, `quote`, `quote_signature`, `EK public`, optional `EK certificate`, optional `EK certificate URL` を生成できる
- server verifier は canonical `tpm2-windows-v1` の quote / signature verify に加え、quote `extraData` として raw `sha256(attestedPublicKeySPKI) + nonce` と compact `sha256(sha256(attestedPublicKeySPKI) + nonce)` の両方を accept する。compact path は GCP Windows VM の vTPM で raw binding が `structure is the wrong size` になるケースへの compatibility fallback である
- live `scep-server-vm` には current local `scepserver-opt` を再配備済みで、legacy `attestation_e2e.sh` と canonical `attestation_e2e_canonical.sh` の両方に加え、`scep-client-vm` からの real canonical `PKIOperation` も journal 上で複数回 `error=null` を確認した
- live `scep-client-vm` では初回 helper-rollout validation run `copilot-tpm-20260324T045007Z-2607` の前後で active managed `cert.pem` の thumbprint が `F091FC0B501ED5F1D411CE3D7CB614FEDE3EA013` から `95704812F1CA69AD8C82058A750D023B4622EF89` に変化し、その後 committed harness `windows_canonical_renewal_e2e.sh` の run `copilot-install-20260324T072948Z-20956` では `0E477BA2EB3446B3DDA4EC5FFA7AD5000B653913` から `61A35E36ED0C8CF639DBA50C4EFE3A7CBE76C4FE` への same-key renewal rotation を再確認した
- `infra/terraform/scripts/test/windows_canonical_renewal_e2e.sh` を追加し、`build_windows_msi.sh` / `install_windows_msi.sh` を束ねて managed `cert.pem` と `LocalMachine\\My` の current-run thumbprint を比較できる committed validation path を用意した。GCP 検証では server internal IP を既定にし、renewal harness では current-run renewal を観測するため `--apply-registry-overrides` を使う。一方で lower-level install helper 自体には stale-config detection 後の auto fresh-install fallback を追加済みである
- Rust service は Windows attestation build phase で helper `-emit-attestation` を呼び出し、返却 payload の nonce / `device_id` / public key / quote fields を検証するところまで source に寄せた。actual TPM quote generation backend 自体は引き続き Go helper に依存するが、helper / Rust / server decode は credential activation 用に `aik_tpm_public_b64`, `ek_public_b64`, `ek_certificate_url`, `activation_id`, `activation_proof_b64` を扱えるよう更新済みである
- server / helper / Rust の 3 者で credential activation round-trip を source に実装済みである。server は `/api/attestation/activation/start` で one-time challenge を払い出し、helper は Windows TPM 上で `ActivateCredential` を実行し、final attestation verifier は `activation_id` / `activation_proof_b64` を nonce consume 前に one-time verify する
- live GCP では managed Windows client `msi-neg-20260325050312` を `preregister_client.sh --managed-client-type windows-msi` で登録し、Windows MSI install probes 後の external `GET /api/client/msi-neg-20260325050312` が `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返すことを確認した。既存 activation client `msi-activation-20260325014801` についても managed thumbprint=`539779D92B8EB0E463C0CC547E8819B7E6E0E212`, `service_state=Running` を継続確認した
- live negative では `POST /api/attestation/activation/start` の endpoint-layer rejection (`403 nonce mismatch`, `400 ek_public_b64 is not a valid SubjectPublicKeyInfo`) に加え、clean rerun `copilot-install-20260325T053507Z-2543` が `activation_negative.renewal_exit_code=1`, `managed_thumbprint_before=managed_thumbprint_after=24E1087234C045FBEB6DC3E2A65646908AD9024A`, `service_state=Running` を返した。live `scep-server-vm` journal でも `2026-03-25T05:35:49Z` に `invalid attestation: invalid_activation_proof` を確認し、tampered `activation_proof_b64` renewal の negative semantics を committed helper path で回収できた

### Implemented In Source

#### Server

- `device_id` の正規化と登録時バリデーションを追加済み
- admin API の client attributes で optional `attestation_aik_spki_sha256` / `attestation_ek_cert_sha256` を受け付け、SHA-256 fingerprint として正規化・バリデーションする処理を追加済み
- admin API の client attributes で optional `managed_client_type` を受け付け、`windows-msi` を正規化・バリデーションする処理を追加済み
- deprecated な `attestation_activation_required` は add/update で reject し、既存 Windows 管理対象は `managed_client_type=windows-msi` へ明示 migration する方針へ切り替え済み
- attestation nonce 専用 REST API を追加済み
- attestation activation 専用 REST API `POST /api/attestation/activation/start` を追加済み
- attestation JSON の decode と `device_id` 照合を追加済み
- attestation JSON decode は `aik_tpm_public_b64`, `ek_public_b64`, `ek_certificate_url`, `activation_id`, `activation_proof_b64` を含む canonical payload も保持できるよう更新済み
- attestation 側の公開鍵と CSR 公開鍵の一致確認を追加済み
- nonce の払い出しと one-time consume を追加済み
- activation challenge の払い出しと one-time verify / consume を追加済み
- `server/attestation_quote.go` を追加し、canonical `tpm2-windows-v1` 向けに TPM quote / TPM signature parse と署名検証を実装済み
- canonical format では quote `extraData` として raw `sha256(attestedPublicKeySPKI) + nonce` と compact `sha256(sha256(attestedPublicKeySPKI) + nonce)` の両方を受理し、blank / unknown format を reject するように harden 済み
- registered client attribute に `attestation_aik_spki_sha256` / `attestation_ek_cert_sha256` が存在する場合、attestation payload の `aik_public_b64` / `ek_cert_b64` から算出した SHA-256 fingerprint と一致しない要求を reject する verifier slice を追加済み
- `managed_client_type=windows-msi` の client では `device_id` を必須にし、`activation_id` / `activation_proof_b64` が欠ける canonical attestation を reject する verifier slice を追加済み
- rollout compatibility のため、placeholder format (`tpm2-windows-v1-placeholder-*`) と current Terraform helper format (`test-nonce-key-binding-v1`) は引き続き許可している
- `infra/terraform/scripts/test/attestation_e2e_canonical.sh` を追加し、canonical `tpm2-windows-v1` payload を GCP 上で positive / negative validate できるようにした
- transport / unit test を追加済み。focused local validation として `go test ./cmd/scepclient ./server -run 'Test(Attestation|DecodeAttestation|LookupDeviceID|VerifyAttestedPublicKey|MySQLDeviceIDAttestationVerifier|VerifyTPMQuoteAttestation)'`, `go test ./server/handler -run 'TestNormalizeClientAttributes'`, `go test ./utils/... ./challenge/... ./cryptoutil/... ./cryptoutil/x509util/... ./scep/... ./depot/bolt/...`, `cargo test --manifest-path rust-client/service/Cargo.toml`, `GOOS=windows GOARCH=amd64 go build ./cmd/scepclient`, `cargo build --manifest-path rust-client/service/Cargo.toml --release --target x86_64-pc-windows-gnu` を通過済み

現在の到達点:

- Phase 1 から Phase 2 への途中段階
- `missing_device_id`, `device_id_mismatch`, `invalid_attestation_format`, `nonce_mismatch`, `public_key_mismatch`, `invalid_quote_signature`, `aik_public_mismatch`, `ek_cert_mismatch`, `missing_activation_proof`, `invalid_activation_proof` 相当の判定は local source で実装済み
- `server/attestation_quote_test.go` で canonical success、compact extraData success、blank / unknown format rejection、missing quote fields、nonce mismatch、public key mismatch、invalid quote signature を focused にカバー済み
- credential activation path は local source に実装済みで、`managed_client_type=windows-msi` の client に対しては payload-supplied AIK/EK material だけで issuance が完了しないようになった。一方で unmanaged client は rollout compatibility のため従来 path を引き続き許可している
- canonical verifier slice は current local binary として live `scep-server-vm` に再配備済みで、legacy / canonical の両 helper で GCP 実測を取り直した

#### Rust Windows Service

- 設定モデルを `server_url`, `client_uid`, `enrollment_secret`, `device_id`, `poll_interval`, `renew_before`, `log_level` に整理済み
- レジストリ値から `EnrollmentSecretProtected` を読み、DPAPI Machine Scope へ移行する処理を実装済み
- サービス状態機械を実装済み
- server nonce API を使う initial / renewal 用 nonce fetch を実装済み
- Windows CNG / NCrypt を使う persisted key path を source に実装済み
- `LocalMachine\\My` への証明書 install と既存証明書 probe を source に実装済み
- Go helper `cmd/scepclient` は generic key path に対応済みで、Windows persisted key provider / name / public SPKI を受け取り、placeholder / canonical attestation を real `tpm2-windows-v1` payload へ upgrade できる
- Rust service は Windows attestation build phase で helper `-emit-attestation` を呼び出し、返却された canonical payload の nonce / normalized `device_id` / public key SPKI / required quote fields を検証するよう更新済み
- `cmd/scepclient -emit-attestation` は `-public-key-spki-b64` を省略した場合でも persisted key から SPKI を自動導出でき、credential-activation probe や future activation round-trip で key name ベースに利用できる
- helper 側では server nonce を受けた canonical attestation build 中に `/api/attestation/activation/start` を呼び、Windows TPM 上で `ActivateCredential` を実行して `activation_id` / `activation_proof_b64` を final payload へ載せるところまで実装済み
- Rust service は helper attestation assembly 呼び出し時に `-uid` と `-server-url` を渡し、返却 payload に activation fields が必要な場合はそれらも検証する
- config load は `poll_interval > renew_before` を warning として surface し、Machine Store から得た `NotBeforeUnix` / `NotAfterUnix` をもとに effective renewal window を `min(renew_before, certificate_lifetime - poll_interval)` へ clamp するよう更新済み
- `Issued` state の next tick は `poll_interval` と renewal window opening の早い方で起床するため、pathological な `renew_before` 設定でも fresh certificate の直後に過早 renewal へ戻り続けない

現在の到達点:

- 初回発行の TPM/CNG 経路は source と GCP 実測の両方で確認済み
- same-key renewal submit は server 側の certificate-based authorization を含めて GCP 上で end-to-end 確認済み
- renewal certificate replacement は同一 key name を維持したまま `LocalMachine\\My` に繰り返し install できることを GCP で確認済み
- Windows Machine Store probe script は managed `cert.pem` の parse 失敗を握りつぶさず simple-name fallback へ進むよう harden 済み
- `cmd/scepclient/attestation_windows.go` では `go-attestation` の temporary Windows `AK` を使って `AIK public`, `quote`, `quote_signature` を生成し、raw binding が失敗した場合は compact binding へ fallback する
- 同 helper は credential-activation pivot 用に raw `AIK TPM public` と `EK public` も canonical payload へ載せるよう更新済みであり、live GCP probe では `EK certificate` は absent だが `AIK TPM public` / `EK public` は present を確認した
- live GCP validation では prior `TPM2_Quote ... structure is the wrong size` blocker を compact fallback で通過し、current server binary に canonical `PKIOperation` を送れる状態まで到達した
- Rust service は attestation assembly の entry point を service 側へ寄せたが、Windows TPM quote backend 自体は引き続き helper-side implementation に依存する

#### MSI / Packaging / Terraform Docs

- Terraform provider は ADC 限定へ移行済み
- Linux 側の MSI build / copy 手順を README に追記済み
- `installer/main.wxs` には GUI / silent install 方針と `LocalService` 前提を反映済み
- `installer/main.wixl.wxs` は `scepclient.exe` を含む silent-install 向け source として更新済み
- `build_windows_msi.sh` の既定 stage dir は `build/windows-msi` へ移行済みで、generated installer 入力を source tree の installer 定義と分離済みである。さらに `--msi-builder auto|wix|wixl` を追加し、`wix` が存在する環境では `installer/main.wxs` + `WixToolset.UI.wixext` を優先し、無い環境では `installer/main.wixl.wxs` へ fallback するよう更新済み
- `installer/main.wxs` は `scepclient.exe` を同梱し、GUI MSI でも service helper を欠かさない状態へ修正済み
- `wixl` の表現力制約で registry ACL 付与を silent MSI に同等実装できないため、`installer/main.wixl.wxs` の service account は authored state では引き続き `LocalSystem` を採用している。2026-03-25 の local probe でも `RegistryKey/Permission` と `Component/RemoveRegistryKey` が `unhandled child` として reject され、silent MSI の uninstall cleanup semantics も GUI MSI とまだ揃えられないことを再確認した
- `infra/terraform/scripts/windows/install-mytunnelapp.ps1` は compact summary marker、thumbprint-change wait、post-install registry override、service restart wait、same-version reinstall 後の stale config を検出して fresh-install へ retry する reconfiguration fallback に加え、`--converge-to-local-service` で `C:\\ProgramData\\MyTunnelApp` への filesystem ACL 付与、`HKLM:\\SOFTWARE\\MyTunnelApp` への registry ACL 付与、`MyTunnelService` の `NT AUTHORITY\\LocalService` への runtime reconfiguration を行えるよう更新済み
- `infra/terraform/scripts/linux/install_windows_msi.sh` は serial wait grace、`--require-thumbprint-change`、`--apply-registry-overrides`、`--converge-to-local-service` を備え、`--server-url` 省略時は Terraform 出力の `server_internal_ip` を優先し、reconfiguration 用には stale-config detection 後の auto fresh-install fallback を利用できる
- `infra/terraform/scripts/test/windows_canonical_renewal_e2e.sh` と `windows_activation_negative_renewal_e2e.sh` は `--msi-builder auto|wix|wixl` を `build_windows_msi.sh` へ forward でき、さらに `install_windows_msi.sh --converge-to-local-service` を通すため、将来の WiX v4 path 検証と current `wixl` fallback の LocalService runtime validation を wrapper script の編集なしで行える
- `installer/main.wxs` / `installer/main.wixl.wxs` では registry-searched existing values と public input properties を分離し、default / existing / explicit input の precedence を custom action で表現する slice を追加した

注意:

- Windows startup script は placeholder bootstrap のままであり、Terraform だけで MSI / service 本体を再現する最終実装にはまだなっていない
- 今回の Windows serial probe では metadata の `windows-startup-script-ps1` を一時的に差し替えたが、検証後に `infra/terraform/scripts/windows/windows-client-startup.ps1` に戻してある

### Verified On GCP

#### Terraform / VM State

- local `infra/terraform` には当初 `terraform.tfstate` が存在しなかったため、network / subnet / firewall / VM を import して state を再構築し、`terraform apply -refresh-only` で output を復元した
- Terraform は `scep-server-vm` と `scep-client-vm` を作成する構成である
- Windows VM は `enable_vtpm = true`, `enable_secure_boot = true`, `enable_integrity_monitoring = true`
- live GCP 側では両 VM が一度 `TERMINATED` になっていたため、起動後に `RUNNING` を確認し、作業終了時に再び `TERMINATED` へ戻した
- imported firewall rules は古い operator IP を向いていたため、current source IP に合わせて Terraform の targeted apply で `scep` / `ssh` / `rdp` rule を同期した
- 現時点では検証環境は破棄しておらず、そのまま追加検証を継続できる。ただし次回は `scep-server-vm` / `scep-client-vm` を起動してから検証に入ること

#### Server VM Runtime

- `http://<server_external_ip>:3000/admin/api/ping` は `pong` を返す
- `GetCACaps` は `Renewal`, `SHA-1`, `SHA-256`, `AES`, `DES3`, `SCEPStandard`, `POSTPKIOperation` を返す
- `POST /api/attestation/nonce` は live 環境で動作している。unknown client に対しては `404 client not found`、preregister 済み client に対しては nonce 払い出しまで確認した
- SSH / `systemctl` / `ss` で `mariadb.service` active、`scep-server.service` active、`scepserver-opt` が `*:3000` listen を確認した
- `infra/terraform/scripts/linux/build_and_scp_scepserver.sh` で current local `scepserver-opt` を live `scep-server-vm` に再配備し、service restart 後も `admin/api/ping` が `pong` を返すことを確認した
- `infra/terraform/scripts/test/preregister_client.sh` と legacy `attestation_e2e.sh` を live server に対して実行し、`success_matching_device_id`, `failure_mismatched_device_id`, `failure_invalid_attestation` を確認した
- `infra/terraform/scripts/test/attestation_e2e_canonical.sh` を live server に対して実行し、`success_matching_device_id`, `failure_mismatched_device_id`, `failure_invalid_quote_signature` を確認した

判断:

- Linux 側の remote SCEP server VM は HTTP endpoint、nonce API、service process、legacy attestation verify path、canonical quote verifier path の観点で正常動作している
- `attestation_e2e_canonical.sh` 自体は引き続き synthetic quote/signature で server semantics を検証する helper だが、本 session では別途 updated Windows helper を `scep-client-vm` に配備して real Windows TPM-backed canonical path も実測した

#### Windows VM Runtime

今回の serial / startup-script probe ベース検証では以下を観測した。

- `HKLM:\\SOFTWARE\\MyTunnelApp` は存在し、active client は `client_uid=msi-stable-20260318051422`, `device_id=device-20260318051422` を保持している
- `MyTunnelService` は存在し、`Running` を返した
- `C:\\ProgramData\\MyTunnelApp\\managed` 配下には 5 個の managed directory があり、active path は `C:\\ProgramData\\MyTunnelApp\\managed\\msi-stable-20260318051422-device-20260318051422` である
- active managed directory には `cert.pem` が存在し、`key.pem` は存在しない
- validation run `copilot-tpm-20260324T045007Z-2607` では local build の `scepclient.exe` を配備し、`before_thumb=F091FC0B501ED5F1D411CE3D7CB614FEDE3EA013` を記録したうえで forced same-key renewal を起動した
- live `scep-server-vm` journal は `2026-03-24T04:51:51Z` に canonical `tpm2-windows-v1` attestation を含む `PKIOperation` `error=null` を記録した
- follow-up probe `copilot-probe-20260324T050656Z-16262` は `key_name=msi-stable-20260318051422-device-20260318051422`, managed `cert.pem` thumbprint=`95704812F1CA69AD8C82058A750D023B4622EF89`, `service_state=Running` を返し、active managed certificate の rotation を確認した
- lower-level install helper run `copilot-install-20260324T072248Z-22747` では internal URL (`http://10.42.0.4:3000/scep`) と post-install registry override を使い、managed `cert.pem` thumbprint が `51C7CC4A759F203C93EC2596ED6574C45AB3F5D3` から `634DBE96F474803063FB5B99FF9777C9B4FA888A` へ変化し、`LocalMachine\\My` でも同 thumbprint を確認した
- committed harness run `copilot-install-20260324T072948Z-20956` では `windows_canonical_renewal_e2e.sh` 経由で managed `cert.pem` thumbprint が `0E477BA2EB3446B3DDA4EC5FFA7AD5000B653913` から `61A35E36ED0C8CF639DBA50C4EFE3A7CBE76C4FE` へ変化し、`present_in_machine_store=true` と `service_state=Running` を返した
- 同 run の service log excerpt は `poll_interval_secs=10`, `renew_before_secs=32400000`, `log_level=debug` を反映し、`RenewalDue -> Issued` 遷移を current-run marker つきで返した
- live `scep-server-vm` journal は `2026-03-24T07:23:17Z`, `07:23:23Z`, `07:23:26Z`, `07:23:40Z`, `07:23:52Z` に加え、committed harness rerun でも `07:31:04Z`, `07:31:16Z`, `07:31:28Z` に host `10.42.0.2` から canonical `tpm2-windows-v1` attestation 付き `PKIOperation error=null` を記録した
- external server URL (`http://34.70.71.128:3000/scep`) を registry override した run では nonce fetch が `curl: (28) Could not connect to server` で失敗し、GCP 検証では internal URL を既定にする必要を確認した
- same-version reinstall test `copilot-install-20260324T074001Z-7067` では `REINSTALL=ALL REINSTALLMODE=vomus` つきで `POLL_INTERVAL=17s`, `RENEW_BEFORE=8000h`, `LOG_LEVEL=info` を渡しても、post-install registry は `10s` / `9000h` / `debug` のまま残った。renewal 自体は走ったが、advanced property override は current live path では未反映である
- fresh-install test `copilot-install-20260324T074424Z-20040` では `--force-fresh-install` を使うことで registry 値が `19s` / `7000h` / `info` に更新され、`present_in_machine_store=true` と `service_state=Running` を維持した。same-key renewal の rotation までは起きなかったが、post-install registry override を使わずに新しい config を反映できることを確認した
- latest reconfiguration validation run `copilot-install-20260324T081949Z-29988` では lower-level install helper が initial reinstall registry (`19s` / `7000h` / `info`) と requested config (`23s` / `6000h` / `error`) の不一致を検出し、auto fresh-install fallback を実施した。final summary では `reconfigure_fallback_used=true`, `fresh_install_requested=true`, `service_state=Running`, `present_in_machine_store=true`, registry=`23s` / `6000h` / `error`, `fresh_install_removed_products=[{product_code={BF6BF605-195A-4F39-89EB-1FCA4DA91AAE}, exit_code=0}]` を確認した
- `copilot-ek-probe-20260325T011838Z-7222` では updated helper を単体実行し、`format=tpm2-windows-v1`, `has_aik=true`, `has_quote=true`, `has_quote_signature=true`, `ek_certificate.present=false` を確認した。current GCP Windows vTPM path では `ek_cert_b64` は取得できない
- `copilot-activation-probe-20260325T012444Z-1288` では同 helper の credential-activation precursor fields を確認し、`has_aik_tpm_public=true`, `has_ek_public=true`, `has_ek_cert=false`, `ek_certificate_url=null` を取得した。GCP Windows vTPM では `EK certificate` は absent だが、activation に必要な `AIK TPM public` / `EK public` は取得できる
- activation-managed install validation では `CLIENT_UID=msi-neg-20260325050312`, `DEVICE_ID_OVERRIDE=device-neg-20260325050312`, internal `SERVER_URL=http://10.42.0.4:3000/scep` を使い、external `GET /api/client/msi-neg-20260325050312` が `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返すことを確認した
- clean negative rerun `copilot-install-20260325T053507Z-2543` では new client `msi-neg-20260325-runner-a` に対して `activation_negative.renewal_exit_code=1`, `managed_thumbprint_before=managed_thumbprint_after=24E1087234C045FBEB6DC3E2A65646908AD9024A`, `present_in_machine_store=true`, `service_state=Running` を current-run summary から確認した
- 既存 credential activation client `msi-activation-20260325014801` については managed thumbprint=`539779D92B8EB0E463C0CC547E8819B7E6E0E212`, `service_state=Running`, `has_enrollment_secret=false`, `has_enrollment_secret_protected=true` を継続確認した
- external `POST /api/attestation/activation/start` に対する live negative check では、bogus nonce が `403 nonce mismatch`、valid nonce に対する invalid `ek_public_b64` が `400 ek_public_b64 is not a valid SubjectPublicKeyInfo` を返した
- `install_windows_msi.sh` の lower-level validation では external IP default が nonce fetch failure を起こすことを再確認したため、helper の既定 `SERVER_URL` を `server_internal_ip` 優先へ変更した
- fresh LocalService convergence run `copilot-install-20260325T070546Z-17570` では new client `msi-localsvc-ok-20260325070516` を `service.start_name=NT AUTHORITY\\LocalService`, `present_in_machine_store=true`, `managed_thumbprint=29FF8482FBAEC855CAAC49B67F2ECF632295FC0E`, `has_enrollment_secret=false`, `has_enrollment_secret_protected=true` で収束させ、external `GET /api/client/msi-localsvc-ok-20260325070516` が `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返すことを確認した
- same-version reinstall LocalService renewal run `copilot-install-20260325T070729Z-4061` では同 client を `NT AUTHORITY\\LocalService` のまま `29FF8482FBAEC855CAAC49B67F2ECF632295FC0E` から `CA46C3C29159BB0F8E9C6127705449814B819B3D` へ回転させ、`managed_thumbprint_changed=true`, `present_in_machine_store=true`, `reinstall_requested=true` を確認した
- probe / validation output に含まれる `badRequest (2)` は pre-rollout attempts 由来の historical service log tail であり、current validation id が prefix されるだけなので current-run failure とみなさない
- current reboot-time grep では `Microsoft Platform Crypto Provider` 文字列も managed-file fallback 文字列も latest log からは再検出できなかった
- probe 中に GCE CorePlugin の MDS bootstrap が `TPM is in DA lockout mode` warning を出した

判断:

- live Windows VM は updated helper を使って real canonical attestation を current live server へ submit でき、managed certificate を回転させながら `MyTunnelService` の `Running` を維持したと判断できる
- active client の `key.pem` 不在は引き続き TPM / CNG persisted-key path と整合的である
- committed validation harness で post-renewal の managed / Machine Store thumbprint を current-run marker 付きで採取できる positive path は維持されている
- `managed_client_type=windows-msi` client の fresh install issuance が live GCP で `ISSUED` まで到達したため、managed-client model + credential activation 自体は server / helper / Rust / MSI wiring を含めて end-to-end で成立している
- tampered `activation_proof_b64` renewal の committed helper path (`install_windows_msi.sh --tamper-activation-proof-renewal`) は live GCP で clean summary 付きに成功した。repeated reset に伴う TPM DA lockout warning は運用上の注意点として残るが、Phase 2 negative semantics 自体は live で確認済みである
- `wixl` fallback MSI は authored state ではなお `LocalSystem` だが、runtime convergence helper (`install_windows_msi.sh --converge-to-local-service`) を通した live GCP validation では fresh install issuance と same-key renewal の両方が `NT AUTHORITY\\LocalService` で成立した
- current GCP Windows vTPM path では `EK certificate` chain validation は成立しない。`EK certificate` は取得できない一方、`AIK TPM public` と `EK public` は取得できるため、trust hardening は credential activation path へ pivot するのが妥当である
- repeated reboot / probe による TPM DA lockout warning があるため、Windows 側の追加実験では reset を短時間に繰り返しすぎないこと

### Remaining Gaps Against This Plan

#### Phase 1 Gaps

- Windows startup script が placeholder のままで、Terraform だけで MSI / service 実装が再現される状態ではない
- `build_windows_msi.sh` は `wix` がある環境では `installer/main.wxs` を source of truth として使えるようになったが、このワークスペースにはまだ `dotnet` / `wix` が入っていないため、現時点の local / GCP validation path はなお `wixl` fallback が中心である
- `wixl` fallback は raw MSI authoring 上はなお `LocalSystem` + uninstall cleanup gap を残すが、supported helper path (`install_windows_msi.sh --converge-to-local-service`) では live GCP で `LocalService` runtime へ収束できる

#### Phase 2 Gaps

- Rust service は attestation assembly の entry point を service 側へ寄せ済みで、Windows TPM quote generation backend は当面 Go helper 実装を正式構成として扱う方針に合意した。Rust-native backend への移行判断は後続フェーズへ送る
- committed GCP validation artifact は `infra/terraform/scripts/test/windows_canonical_renewal_e2e.sh` として追加済みであり、reconfiguration 用の lower-level helper には stale-config detection + auto fresh-install fallback を追加済みである。raw same-version `msiexec` semantics 自体はなお旧 registry 値に負けるが、supported helper path では requested config を最終的に反映できる
- managed-client model (`managed_client_type=windows-msi`, `device_id` 必須, deprecated `attestation_activation_required` reject) と preregistration / frontend create-list / client info edit surfaces は source に反映済みである。frontend の admin mode では InfoPage から `managed_client_type`, `device_id`, 追加属性を更新できる
- `windows_activation_negative_renewal_e2e.sh` と lower-level `--tamper-activation-proof-renewal` wiring は source に追加済みで、live helper rerun `copilot-install-20260325T053507Z-2543` まで current-run summary 付きで成功した。remaining concern は runbook の存在ではなく、GCP guest agent の TPM DA lockout warning を避けるため rerun 間隔に注意が必要な点である

#### Phase 3 Gaps

- renewal scheduling guardrail 自体は local source に実装済みで、`poll_interval > renew_before` warning、effective renewal clamp、Issued-state wake-up shortening を `cargo test --manifest-path rust-client/service/Cargo.toml` と `cargo build --manifest-path rust-client/service/Cargo.toml --release --target x86_64-pc-windows-gnu` で確認済みである。ただし pathological config を live GCP で再観測したわけではない
- forced renewal validation では同一 CN の証明書が Machine Store に積み上がるため、運用時の cleanup / retention policy は引き続き未確定である

### Recommended Next Actions

次セッションは以下の順で進めること。

1. 既存 Windows 管理対象 client の migration runbook を docs に落とし切る
2. renewal guardrail の live GCP runbook と certificate cleanup / retention policy を整理し、必要なら追加 validation を行う
3. Windows startup script placeholder 依存を引き続き縮めつつ、WiX v4 toolchain を入れた環境で `build_windows_msi.sh --msi-builder wix` を実 build / 実 VM 検証し、`installer/main.wxs` path を Linux build の primary に昇格できるか確認する。`wixl` fallback に残る raw MSI uninstall cleanup 差分には引き続き別対策が必要である
4. repeated Windows validation run で guest agent が `TPM is in DA lockout mode` warning を出しうるため、reboot-heavy probe の cadence と runbook を整理する

### Session Handoff Notes

- `infra/terraform` の local state は import により再構築済みで、`terraform output` は live GCP 状況と再同期済みである
- `terraform.tfvars` には placeholder source range が残っているため、接続不能時は current operator IP に合わせた firewall 更新が必要になる
- validation 中に一時的に `scep-vpc-allow-scep-3000` を `0.0.0.0/0` へ広げたが、作業終了前に `35.233.235.22/32` へ戻してある
- 現時点の Terraform state は live で、`scep-server-vm` / `scep-client-vm` は残っている。今回の validation では一度起動して `copilot-ek-probe-20260325T011838Z-7222` / `copilot-activation-probe-20260325T012444Z-1288` / `copilot-install-20260325T015247Z-21208` を実行し、作業終了時点では再び両方とも停止済みである
- `scep-server-vm` は local server ではなく GCP 上の remote server を前提に検証すること
- `infra/terraform/scripts/linux/build_and_scp_scepserver.sh` で current local `scepserver-opt` を live `scep-server-vm` に再配備済みである
- `attestation_e2e.sh` は legacy `test-nonce-key-binding-v1` helper、`attestation_e2e_canonical.sh` は canonical `tpm2-windows-v1` helper であり、後者は synthetic OpenSSL-generated quote/signature を使って server semantics を検証する
- validation run `copilot-tpm-20260324T045007Z-2607` では local `scepclient.exe` を配備し、forced renewal の直前 thumbprint として `F091FC0B501ED5F1D411CE3D7CB614FEDE3EA013` を記録した
- follow-up probe `copilot-probe-20260324T050656Z-16262` では active managed `cert.pem` thumbprint=`95704812F1CA69AD8C82058A750D023B4622EF89`, `service_state=Running`, `key_name=msi-stable-20260318051422-device-20260318051422` を取得した
- `infra/terraform/scripts/test/windows_canonical_renewal_e2e.sh` は current committed Windows renewal harness であり、default では Terraform 出力の `server_internal_ip` を `SERVER_URL` に使い、`--apply-registry-overrides` と `--require-thumbprint-change` を通じて current-run thumbprint rotation を検証する
- successful committed-harness run `copilot-install-20260324T072948Z-20956` では managed thumbprint が `0E477BA2EB3446B3DDA4EC5FFA7AD5000B653913` から `61A35E36ED0C8CF639DBA50C4EFE3A7CBE76C4FE` へ回転し、`present_in_machine_store=true` を返した
- same-version reinstall run `copilot-install-20260324T074001Z-7067` は renewal 自体は成功したが、requested `17s` / `8000h` / `info` の代わりに registry が `10s` / `9000h` / `debug` のまま残った
- `install_windows_msi.sh --force-fresh-install` の run `copilot-install-20260324T074424Z-20040` では registry が `19s` / `7000h` / `info` に更新されたため、advanced property reconfiguration の切り分けには fresh install path が有効である
- latest helper reconfiguration run `copilot-install-20260324T081949Z-29988` では stale-config detection 後の auto fresh-install fallback により final registry を `23s` / `6000h` / `error` へ更新できた。current live client config はこの値に更新済みで、service は `Running`、managed `cert.pem` と `LocalMachine\\My` の双方で thumbprint `5282F95B9414E9981327742EC19BFD048BC5E1DE` を保持していた
- external URL override run では nonce fetch が `curl: (28) Failed to connect to 34.70.71.128 port 3000` で失敗したため、GCP validation では internal URL を使うこと
- `infra/terraform/scripts/linux/install_windows_msi.sh` は 2026-03-25 時点で `--server-url` 省略時に `server_internal_ip` を優先するよう更新済みであり、lower-level helper でも external path を踏みにくくなった
- Windows VM は今回の reboot probe 後も stable config に戻っており、`client_uid=msi-stable-20260318051422`, `device_id=device-20260318051422`, managed `cert.pem` あり / `key.pem` なし、service は `Running` であった
- `copilot-ek-probe-20260325T011838Z-7222` は `ek_certificate.present=false` を返したため、current GCP vTPM path では `EK certificate chain validation` は採用できない
- `copilot-activation-probe-20260325T012444Z-1288` は `has_aik_tpm_public=true`, `has_ek_public=true`, `has_ek_cert=false`, `ek_certificate_url=null` を返した。current slice ではこの material を使う credential activation endpoint / verifier を source に実装済みである
- activation-managed live validation client `msi-neg-20260325050312` は `preregister_client.sh --managed-client-type windows-msi` で登録済みであり、external `GET /api/client/msi-neg-20260325050312` は `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返した
- live negative endpoint checks では `POST /api/attestation/activation/start` に対し bogus nonce が `403 nonce mismatch`、valid nonce + invalid `ek_public_b64` が `400 ek_public_b64 is not a valid SubjectPublicKeyInfo` を返した
- clean helper rerun `copilot-install-20260325T053507Z-2543` では new client `msi-neg-20260325-runner-a` に対し `activation_negative.renewal_exit_code=1`, `managed_thumbprint_before=managed_thumbprint_after=24E1087234C045FBEB6DC3E2A65646908AD9024A`, `present_in_machine_store=true`, `service_state=Running` を current-run summary から取得した。external `GET /api/client/msi-neg-20260325-runner-a` は `status=ISSUED`, `attributes.managed_client_type=windows-msi` を返した
- live server journal では 2026-03-25T05:12:37Z, 05:14:29Z, 05:22:31Z に加え、clean rerun 時刻 05:35:49Z にも `invalid attestation: invalid_activation_proof` を確認した。repeated reboot に伴う TPM DA lockout warning は引き続き運用上の注意点である
- fresh LocalService helper run `copilot-install-20260325T070546Z-17570` では new client `msi-localsvc-ok-20260325070516` が `service.start_name=NT AUTHORITY\\LocalService`, `managed_thumbprint=29FF8482FBAEC855CAAC49B67F2ECF632295FC0E`, `present_in_machine_store=true`, `has_enrollment_secret=false`, `has_enrollment_secret_protected=true` で `ISSUED` になった
- follow-up same-key renewal run `copilot-install-20260325T070729Z-4061` では同 client が `NT AUTHORITY\\LocalService` を維持したまま thumbprint `29FF8482FBAEC855CAAC49B67F2ECF632295FC0E` から `CA46C3C29159BB0F8E9C6127705449814B819B3D` へ回転した。live `scep-server-vm` journal でも `2026-03-25T07:06:43Z` と `07:08:01Z` に host `10.42.0.2` から canonical `PKIOperation error=null` を確認した
- shared understanding として、current server/admin model は `managed_client_type=windows-msi` による Windows 管理対象識別、`device_id` 必須化、activation 必須化、既存 client の明示 migration を前提にする。helper-backed TPM path は当面の正式構成として扱い、Rust-native backend は後続フェーズで再判断する
- temporary metadata probe は検証後に `infra/terraform/scripts/windows/windows-client-startup.ps1` へ戻してある
- repeated reboot / probe で GCE guest agent 側の MDS bootstrap が TPM DA lockout warning を出すため、次の Windows 側検証では reset の間隔に余裕を持たせること
- forced renewal validation で使った `msi-renew-*` 系の CN には複数の旧証明書が残っているため、運用 cleanup を試す場合はその CN を対象にすること
- 2026-03-25 の local probe では `wixl` が `RegistryKey/Permission` と `Component/RemoveRegistryKey` を `unhandled child` として reject した。supported helper path は runtime convergence で `LocalService` を満たせるが、raw silent MSI を `LocalService + uninstall cleanup semantics` へ寄せるには、WiX v4 build path か別 custom action 戦略が必要である
- `build_windows_msi.sh` は current source で `--msi-builder auto|wix|wixl` を受け付け、fake `wix` を使った local control-flow validation では `wix extension add WixToolset.UI.wixext` と `wix build -arch x64 -ext WixToolset.UI.wixext -o ... installer/main.wxs` を呼ぶこと、および `rust-client/target/release/service.exe` を含む staging を確認済みである
- generated wixl staging は `build/windows-msi` を見ること。`installer/` 配下の source と混同しないこと
- MySQL を要求する server test はローカル環境依存で失敗しうるため、GCP 検証とは分けて扱うこと

## Definition of Done

- GUI / サイレント install の両方で Windows Service を導入できる
- TPM-backed key を用いた初回発行が成功する
- SCEP サーバーが登録済み `device_id` と attestation を検証する
- 不正な attestation を拒否できる
- 自動更新が期限前に成功する
- GCP + Terraform の検証手順が README だけで再現できる
