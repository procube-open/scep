import polyglotI18nProvider from 'ra-i18n-polyglot';
import en from 'ra-language-english';
import ja from '@bicstone/ra-language-japanese';

const english = {
  ...en,
  client: {
    title: "Client",
    editTitle: "Issue Certificate in #PKCS12 Format",
    empty: "No clients found.",
    create: "Register",
    created: "Client created.",
    updated: "Client updated.",
    revoke: "Revoke",
    revoked: "Client revoked.",
    updateTitle: "Manage Client Attributes",
    dialog: {
      title: "New Client",
    },
    status: {
      INACTIVE: "Inactive",
      ISSUABLE: "Issuable",
      ISSUED: "Issued",
      UPDATABLE: "Updatable",
      PENDING: "Pending",
    },
    fields: {
      uid: "Client ID",
      status: "Status",
      secret: "Secret",
      managed_client_type: "Managed Client Type",
      device_id: "Device ID",
      device_id_helper: "Required for Windows MSI managed clients.",
      additional_attributes: "Additional Attributes (JSON)",
      attributes: "Attributes",
    },
    managedClientType: {
      none: "Not managed",
      windows_msi: "Windows MSI 管理対象",
    },
  },
  cert: {
    listTitle: "Certificate List",
    password: "File Password",
    pkcs12Download: "Issue Certificate",
    certDataTitle: "Client Certificate",
    empty: "No certificates issued.",
    copySuccess: "Certificate copied to clipboard.",
    copy: "Copy",
    fields: {
      serial: "Serial Number",
      status: "Valid/Invalid",
      valid_duration: "Validity Period",
      revocation_date: "Revocation Date",
    }
  },
  file: {
    downloading: "Downloading...",
    downloaded: "Download complete",
  },
  files: {
    title: "Downloads",
    empty: "No files found.",
    copySuccess: "URL copied to clipboard.",
    download: "Download/Copy URL",
    fields: {
      name: "File Name",
      size: "Size",
    }
  },
  secret: {
    createTitle: "Create Secret",
    create: "Create",
    created: "Secret created.",
    fields: {
      secret: "Secret",
      delete_at: "Expiration Date",
      pending_period: "Pending Period",
      pending_period_suffix: "days",
    }
  },
  error: {
    contentLengthError: "Invalid Content-Length.",
    bodyError: "Could not read file.",
    copyError: "Failed to copy to clipboard.",
    statusError: "Cannot issue certificate for this client.",
    secretError: "Enter client certificate issuance password.",
    passwordError: "Set a password for the certificate file.",
    requiredError: "Required field.",
    parseError: "Input in JSON format.",
    createError: "Creation failed.",
    updateError: "Update failed.",
  },
  other: {
    changeMode: "Admin Mode",
    serviceStatusLoading: "Service: Checking...",
    serviceStatusRunning: "Service: Running",
    serviceStatusStopped: "Service: Stopped",
  }
}


const japanese = {
  ...ja,
  client: {
    title: "クライアント",
    editTitle: "証明書を #PKCS12 形式で発行",
    empty: "クライアントが見つかりません。",
    create: "登録",
    created: "クライアントを作成しました。",
    updated: "クライアントを更新しました。",
    revoke: "失効",
    revoked: "クライアントを失効しました。",
    updateTitle: "クライアント属性の管理",
    dialog: {
      title: "新規クライアント",
    },
    status: {
      INACTIVE: "無効",
      ISSUABLE: "発行可能",
      ISSUED: "発行済",
      UPDATABLE: "更新可能",
      PENDING: "更新待ち",
    },
    fields:{ 
      uid: "クライアントID",
      status: "ステータス",
      secret: "シークレット",
      managed_client_type: "管理対象種別",
      device_id: "デバイスID",
      device_id_helper: "Windows MSI 管理対象では必須です。",
      additional_attributes: "追加属性 (JSON)",
      attributes: "属性",
    },
    managedClientType: {
      none: "通常クライアント",
      windows_msi: "Windows MSI 管理対象",
    },
  },
  cert :{
    listTitle: "証明書一覧",
    password: "ファイルパスワード",
    pkcs12Download: "証明書発行",
    certDataTitle: "クライアント証明書",
    empty: "証明書が発行されていません。",
    copySuccess: "クリップボードに証明書をコピーしました。",
    copy: "コピー",
    fields: {
      serial: "シリアル番号",
      status: "有効/無効",
      valid_duration: "有効期限",
      revocation_date: "失効日時",
    }
  },
  file: {
    downloading: "ダウンロード中...",
    downloaded: "ダウンロード完了",
  },
  files: {
    title: "ダウンロード",
    empty: "ファイルが見つかりません。",
    copySuccess: "クリップボードにURLをコピーしました。",
    download: "ダウンロード/URLコピー",
    fields: {
      name: "ファイル名",
      size: "サイズ",
    }
  },
  secret: {
    createTitle: "シークレットを作成",
    create: "作成",
    created: "シークレットを作成しました。",
    fields: {
      secret: "シークレット",
      delete_at: "有効期限",
      pending_period: "更新前証明書有効期間",
      pending_period_suffix: "日",
    }
  },
  error: {
    contentLengthError: "Content-Lengthが不正です。",
    bodyError: "ファイルを読み込めませんでした。",
    copyError: "クリップボードにコピーできませんでした。",
    statusError: "このクライアントでは証明書を発行できません。",
    secretError: "クライアント証明書発行用パスワードを入力して下さい。",
    passwordError: "証明書ファイルのパスワードを任意に設定して下さい。",
    requiredError: "必須項目です。",
    parseError: "JSON形式で入力して下さい。",
    createError: "作成に失敗しました。",
    updateError: "更新に失敗しました。",
  },
  other:{
    changeMode: "管理モード",
    serviceStatusLoading: "サービス状態: 確認中...",
    serviceStatusRunning: "サービス状態: 稼働中",
    serviceStatusStopped: "サービス状態: 停止中",
  }
}

const translations: any = { english, japanese };

const i18nProvider = polyglotI18nProvider(
  locale => translations[locale],
  'japanese', // default locale
  [{ locale: 'japanese', name: '日本語' }, { locale: 'english', name: 'English' }],
);

export default i18nProvider
