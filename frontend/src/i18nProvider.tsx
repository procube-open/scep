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
    fields:{ 
      uid: "ユーザーID",
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
      status: "ステータス",
      valid_from: "有効期限(開始)",
      valid_till: "有効期限(終了)",
    }
  },
  file: {
    downloading: "ダウンロード中...",
    downloaded: "ダウンロード完了",
  },
  files: {
    title: "ダウンロード",
    empty: "ファイルが見つかりません。",
    fields: {
      name: "ファイル名",
      size: "サイズ",
    }
  },
  error: {
    contentLengthError: "Content-Lengthが不正です。",
    bodyError: "ファイルを読み込めませんでした。",
    copyError: "クリップボードにコピーできませんでした。",
  }
}

const translations: any = { english, japanese };

const i18nProvider = polyglotI18nProvider(
  locale => translations[locale],
  'japanese', // default locale
  [{ locale: 'japanese', name: '日本語' }, { locale: 'english', name: 'English' }],
);

export default i18nProvider