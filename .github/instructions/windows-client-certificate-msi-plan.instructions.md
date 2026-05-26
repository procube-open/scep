# Windows Client Certificate MSI Implementation Plan

最終更新日: 2026-05-26

## Purpose

この文書は、このリポジトリにおける Windows クライアント証明書発行 MSI の**基準文書**である。  
長い検証ログや時系列メモは持たず、**中核となる実装構成・確定済み方針・目標地点・残課題**だけを記す。

詳細な操作手順と運用 runbook の正本は `infra/terraform/README.md` とする。

## Goal

既存の SCEP フローを壊さず、Windows 向け MSI を配布し、インストールされた Windows Service が TPM 保護鍵を用いてクライアント証明書を**初回発行**および**同一鍵での自動更新**できる状態を実現する。

## Scope

- GUI MSI と silent install
- Windows Service による初回発行・自動更新
- TPM-backed key と attestation bundle
- SCEP server 側の `device_id` binding / nonce / credential activation / quote verify
- GCP + Terraform による再現可能な検証

## Non-Goals

- 既存の通常 SCEP クライアントの廃止
- WebUI / REST API の全面刷新
- 初期段階での MDM 連携、多テナント、オフライン登録
- Rust native TPM backend への全面移行を release blocker に含めること

## Glossary

- **TPM / vTPM**: 秘密鍵を OS から直接取り出せない形で保持するセキュリティデバイス。GCP Windows VM では物理 TPM ではなく `vTPM` を使う。
- **CNG / KSP**: Windows で TPM-backed key を扱う標準 API / provider。実装上の「TPM 内で鍵を作る」は「CNG 経由で TPM-backed persisted key を作る」と読む。
- **AIK**: `Attestation Identity Key`。TPM が quote 署名に使う鍵。
- **Quote**: TPM が nonce と PCR 情報を束ねて署名した証跡。
- **PCR**: `Platform Configuration Register`。起動状態などを表す TPM レジスタ。
- **LocalSystem**: 権限の強い組み込みアカウント。release-blocker path の bootstrap 既定。
- **LocalService**: 権限の弱い組み込みアカウント。後続 hardening の対象。

## Fixed Decisions

以下はこの計画で**確定済み**として扱う。

1. Windows 管理対象 client は `managed_client_type=windows-msi` で識別する。
2. canonical `device_id` は **EK public の SubjectPublicKeyInfo DER 全体の SHA-256 を lowercase 64 文字 hex 化した値**とする。
3. preregistration は install 前提とし、installer 自身は client 登録を行わない。
4. GUI MSI を primary flow とする。  
   - Step 1: TPM から canonical `device_id` を probe  
   - Step 2: `SERVER_URL` + `CLIENT_UID` で prereg-check  
   - Step 3: `ENROLLMENT_SECRET` 入力
5. silent install は別配布の `device-id-probe` を prerequisite とし、同じ prereg-check を fail-fast で通す。
6. `managed_client_type=windows-msi` の通常運用 state は `INACTIVE` / `ISSUABLE` / `ISSUED` のみとする。`UPDATABLE` / `PENDING` の legacy update-secret flow は使わない。
7. 初回発行は one-time `enrollment_secret` を使う。更新では使わない。
8. 更新は**同一鍵**を既定とする。再鍵生成は将来オプション。
9. Windows Service は `expected_device_id` を保持し、runtime で毎回 TPM identity を再導出する。不一致なら enrollment / renewal を block する。
10. attestation nonce は server-issued を必須とする。
11. `managed_client_type=windows-msi` では credential activation を必須とする。`EK certificate` は取得できれば保持するが必須条件にはしない。
12. enrollment secret の保存は **DPAPI Machine Scope** を第一候補とし、初回発行成功後は Windows 側から削除する。
13. 証明書格納先は **Windows Machine Store `LocalMachine\\My`** を正式構成とする。
14. release build では `DEVICE_ID_OVERRIDE` を禁止し、test harness / debug build にだけ残す。
15. TPM attestation backend は**当面 Go helper-backed を正式構成**とし、Rust native backend は後続で再判断する。
16. WiX v4 MSI の release-blocker path は **`LocalSystem` bootstrap** とする。`LocalService` 収束は後続 hardening とする。
17. same-version reinstall の再構成は **helper / runbook 経由の安全な path** を正式とし、raw `msiexec` 単体の完全再設定は release blocker にしない。
18. 過去証明書の cleanup は当面自動化しない。retention / cleanup policy は runbook で定義する。
19. Terraform の認証モデルは **ADC 限定**とする。
20. GCP 検証環境の目標トポロジーは **server / client とも private-only** とする。
21. GUI MSI の primary evidence は **UI Automation による `windows_gui_issuance_e2e.sh`** とする。
22. Windows MSI / GCP 検証 runbook の正本は `infra/terraform/README.md` とし、repo root `README.md` はリンク役にとどめる。

## Core Implementation Structure

### 1. Server

server 側の責務は以下である。

- admin API / frontend で `device_id` と `managed_client_type` を add / update できる
- `POST /api/attestation/prereg-check` で preregistration readiness を返す
- `POST /api/attestation/nonce` で one-time nonce を払い出す
- `POST /api/attestation/activation/start` で credential activation challenge を払い出す
- `PKIOperation` で attestation payload を検証する
  - registered `device_id` と request `device_id` の一致
  - `ek_public_b64` からの canonical `device_id` 再導出
  - attested public key と CSR public key の一致
  - quote / signature verify
  - nonce consume
  - activation proof verify
  - renewal 時は既存クライアント証明書で認可

主な実装箇所:

- `server/handler/client.go`
- `server/transport.go`
- `server/attestation.go`
- `server/attestation_prereg.go`
- `server/attestation_nonce.go`
- `server/attestation_activation.go`
- `server/attestation_quote.go`

### 2. Windows MSI / Service

Windows 側の責務は以下である。

- `device-id-probe.exe` または GUI Step 1 で canonical `device_id` を表示する
- GUI Step 2 で prereg-check を行い、`ready` になるまで install を進めない
- MSI が `service.exe`, `scepclient.exe`, `device-id-probe.exe` を配置する
- MSI が `server_url`, `client_uid`, `expected_device_id`, `enrollment_secret`, `poll_interval`, `renew_before`, `log_level` を設定する
- Windows Service が TPM-backed persisted key を作成・再利用する
- Windows Service が nonce を取得し、helper に canonical attestation 生成を委譲する
- 初回発行後に bootstrap secret を削除する
- 既存証明書 + same-key + attestation で自動更新する

主な実装箇所:

- MSI UI / packaging: `installer/main.wxs`
- Windows service config: `rust-client/service/src/config.rs`
- Windows service state machine: `rust-client/service/src/state.rs`
- Windows service platform / DPAPI / Machine Store: `rust-client/service/src/platform.rs`
- Windows service entrypoint: `rust-client/service/src/main.rs`
- device identity / attestation helper: `cmd/scepclient/device_identity.go`, `cmd/scepclient/attestation_windows.go`

### 3. Validation / Packaging

検証と packaging は以下の helper 群で成立している。

- MSI build / transfer: `infra/terraform/scripts/linux/build_windows_msi.sh`
- Windows TPM identity probe: `infra/terraform/scripts/linux/probe_windows_device_id.sh`
- preregistration helper: `infra/terraform/scripts/linux/preregister_client_via_startup.sh`
- silent install / observation helper: `infra/terraform/scripts/linux/install_windows_msi.sh`
- GUI UI Automation evidence: `infra/terraform/scripts/test/windows_gui_issuance_e2e.sh`
- same-key renewal evidence: `infra/terraform/scripts/test/windows_canonical_renewal_e2e.sh`
- tampered activation renewal negative evidence: `infra/terraform/scripts/test/windows_activation_negative_renewal_e2e.sh`

`infra/terraform/scripts/windows/windows-client-startup.ps1` は**placeholder bootstrap**であり、正式 install path ではない。

## Current Implementation Summary

### Implemented

- `managed_client_type=windows-msi` と canonical `device_id` の server-side validation
- prereg-check / nonce / activation endpoints
- canonical `tpm2-windows-v1` attestation verify
- quote signature verify、nonce consume、CSR public key binding
- `activation_id` / `activation_proof_b64` を含む credential activation path
- WiX v4 GUI MSI
  - page 1 TPM probe
  - page 2 prereg-check
  - page 3 enrollment secret
- GCP private-only validation topology
  - `scep-server-vm` / `scep-client-vm` は private-only を正式構成とする
  - `coder-vm` からの operator access は private routing を正式構成とする
- Windows service による `expected_device_id` mismatch block
- `LocalMachine\\My` への証明書 install
- 初回発行後の bootstrap secret cleanup
- same-key renewal path
- GUI / silent / negative renewal の validation harness
- `windows_gui_issuance_e2e.sh` による private-only live GUI evidence
- `windows_canonical_renewal_e2e.sh` による same-key renewal evidence
- `windows_activation_negative_renewal_e2e.sh` による tampered activation renewal rejection evidence
- private-only / UI Automation を primary path とする runbook 整理
- TPM DA lockout の wait budget / cadence と validation semantics の文書化
- `windows-client-startup.ps1` の placeholder bootstrap 位置づけの明確化

### Current Official Interpretation

- TPM attestation backend は helper-backed path を正式構成とする
- WiX v4 の blocker path は `LocalSystem` bootstrap
- GCP 検証トポロジーは `coder-vm` から private routing で到達する private-only 構成を正式とする
- GUI primary evidence は private-only live run の `windows_gui_issuance_e2e.sh` とする
- negative renewal の authoritative field は `renewal_rejected` / `renewal_failure_excerpt` とする
- `windows-client-startup.ps1` は helper / bootstrap 用であり、正式 install path ではない
- `LocalService` は optional hardening path
- detailed runbook は `infra/terraform/README.md`

## Target State

この計画の目標地点は以下である。

1. Windows GUI MSI が **page 1 probe -> page 2 prereg-check -> page 3 ENROLLMENT_SECRET -> install** を通して証明書を取得できる
2. GCP 検証環境は **server / client とも private-only** で再現できる
3. GUI path の release-blocker evidence は **`windows_gui_issuance_e2e.sh`** で取得できる
4. WiX v4 release path の **`LocalSystem` bootstrap** で初回 TPM-backed issuance が成功する
5. `ISSUED` 状態の Windows managed client が、追加 secret なしで **same-key renewal** できる
6. tampered `activation_proof_b64` renewal と prereg-check mismatch を server / helper が拒否できる
7. issued certificate は `LocalMachine\\My` に入り、bootstrap secret は初回成功後に残らない
8. ドキュメントの役割分担が明確である
   - 本文書: 基準文書
   - `infra/terraform/README.md`: 手順の正本

## Remaining Gaps

### Release Blockers

現時点で release blocker はない。以下は解消済みである。

1. **private-only topology**
   - `scep-server-vm` / `scep-client-vm` は private-only を正式構成とした
   - Terraform / helper / outputs / validation assumptions は private-only に収束済みである

2. **GUI primary evidence**
   - `windows_gui_issuance_e2e.sh` による **private-only 環境での live evidence** を取得済みである
   - `gui-mytunnelapp.ps1` は interactive desktop 前提の UI Automation として安定化済みである

3. **runbook cleanup**
   - `infra/terraform/README.md` は `coder-vm` からの private access + UI Automation を primary path とした
   - RDP / public IP 前提の説明は fallback / debugging 用に整理済みである

4. **TPM DA lockout と validation semantics**
   - helper / runbook に wait budget と cadence を明文化済みである
   - tampered renewal の authoritative fields は `renewal_rejected` / `renewal_failure_excerpt` と定義済みである

5. **Windows startup script positioning**
   - `windows-client-startup.ps1` は placeholder bootstrap / helper 用と明確化済みである
   - 正式 install path は MSI / service / validation harness である

### Non-Blocking Hardening

1. **`LocalService` 収束**
   - `install_windows_msi.sh --converge-to-local-service` は存在する
   - ただし blocker は `LocalSystem` bootstrap 成功であり、`LocalService` は hardening 扱い

2. **Rust native TPM backend**
   - 現在は helper-backed が正式構成
   - Rust native backend は後続フェーズで再判断する

3. **証明書 retention / cleanup policy**
   - same-key renewal を繰り返すと Machine Store に過去証明書が積み上がりうる
   - 当面は自動削除しない
   - retention / cleanup の operator policy を runbook に落とす必要がある

4. **raw same-version `msiexec` semantics**
   - raw reinstall 単体では requested config が既存 registry に負けるケースがある
   - これは helper / runbook path で吸収する方針であり、release blocker ではない

## What This Document Intentionally Omits

- 長い時系列の validation run history
- 過去の一時的な調査メモ
- 単発の run ID 群
- operator 向けの詳細コマンド列

それらは session artifact や `infra/terraform/README.md` 側で扱う。  
この文書では、**次の実装判断に必要な定数・構成・目標・差分**だけを保持する。
