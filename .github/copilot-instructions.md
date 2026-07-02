# Copilot Instructions

- Windows クライアント証明書発行自動化 MSI の実装計画は `.github/instructions/windows-client-certificate-msi-plan.md` を参照すること。
- この計画書を、このリポジトリにおける Windows Service、TPM attestation、MSI UI / silent install、GCP Terraform 検証の基準文書として扱うこと。
- 特に `device_id` 事前登録、Terraform の ADC 限定、DPAPI Machine Scope、Windows Machine Store、同一鍵 Renewal の方針は確定事項として扱うこと。
- TPM や Windows Service の設計相談では、用語を省略せず、必要に応じて `TPM`, `vTPM`, `CNG`, `AIK`, `quote`, `PCR`, `LocalService`, `LocalSystem` の意味を説明しながら進めること。