import polyglotI18nProvider from 'ra-i18n-polyglot';
import en from 'ra-language-english';
import ja from '@bicstone/ra-language-japanese';

const english = {
  ...en,
  client: {
    title: "Clients",
    fields:{ 
      uid: "User ID",
      secret: "Secret",
      attributes: "Attributes",
    }
  },
  cert :{
    pkcs12Download: "Issue Certificate"
  }
}

const japanese = {
  ...ja,
  client: {
    title: "クライアント",
    editTitle: "証明書を #PKCS12 形式で発行",
    empty: "クライアントが見つかりません。",
    create: "作成",
    created: "クライアントを作成しました。",
    dialog: {
      title: "新規クライアント",
    },
    fields:{ 
      uid: "クライアントID",
      status: "ステータス",
      secret: "パスワード",
      attributes: "属性",
    }
  },
  cert :{
    password: "ファイルパスワード",
    pkcs12Download: "証明書発行",
    certDataTitle: "クライアント証明書",
    empty: "証明書が発行されていません。",
    copySuccess: "クリップボードにコピーしました。",
    copy: "コピー",
    fields: {
      serial: "シリアル番号",
      status: "有効/無効",
      valid_from: "有効期限(開始)",
      valid_till: "有効期限(終了)",
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
    download: "ダウンロード",
    fields: {
      name: "ファイル名",
      size: "サイズ",
    }
  },
  error: {
    contentLengthError: "Content-Lengthが不正です。",
    bodyError: "ファイルを読み込めませんでした。",
    copyError: "クリップボードにコピーできませんでした。",
    statusError: "このクライアントでは証明書を発行できません。",
    secretError: "クライアントのパスワードを入力して下さい。",
    passwordError: "証明書ファイルのパスワードを任意に設定して下さい。",
  },
  other:{
    changeMode: "Admin",
  }
}

const translations: any = { english, japanese };

const i18nProvider = polyglotI18nProvider(
  locale => translations[locale],
  'japanese', // default locale
  [{ locale: 'japanese', name: '日本語' }, { locale: 'english', name: 'English' }],
);

export default i18nProvider