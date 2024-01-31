# SCEPサーバ
IDMと連携可能なSCEPサーバを構築する。

## サンプル
ローカル環境で構築しテストする場合、Golangを導入し以下のコマンドを実行することで`cert.pem`,`key.pem`,`csr.pem`の三種類のファイルが作られることが確認できる。
```
make

./scepserver-opt ca -init
./scepserver-opt -idmurl {IDM-bindbrokerのURL} -ifname {インターフェース名}

./scepclient-opt -uid {UID} -secret {Password}
```

## IDM設定

### クラス定義
IDMのクラス定義で、参照される属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
| uid     |  文字列  | キー属性として判定され、クライアントの照合に用いられる。"\"が含まれていはいけない。 |
| password | 文字列| クライアントの照合に用いられる。"\"が含まれてはいけない |
| certIss | 日時 | 照合に成功した場合は証明書発行日時を書き込む。 |
|certExp | 日時 | 照合に成功した場合は証明書有効期限を書き込む。|
|certificate | 文字列 | 照合に成功した場合は証明書を書き込む。 |

### インターフェース定義
- [上記の属性](#クラス定義)がインターフェ-ス定義でアクセス可能となっている必要がある。
- `password`属性は平文化されている必要がある。
- フィルタ式で証明書が更新可能なもののみを取得できるようにする。

## Docker構築

### サーバ
`Dockerfile.server`をビルドすることで構築が可能

**環境変数一覧**
| 名前 | デフォルト値|内容|
|--|--|--|
|SCEP_HTTP_LISTEN_PORT|"2016"|サーバのポート番号|
|SCEP_FILE_DEPOT|"idm-depot"|ca.crtとca.keyを保存するフォルダのパス|
|SCEP_CERT_VALID|"365"|証明書の有効期限|
|SCEP_IDM_URL|""|IDM-bindbrokerのURL|
|SCEP_INTERFACE_NAME| "" |証明書を更新可能なユーザ一覧が取得可能なインターフェース名|
|SCEPCA_YEARS|"10"|ca.crtの有効期間(年)|
|SCEPCA_KEY_SIZE|"4096"|ca.keyのサイズ|
|SCEPCA_CN|"Procube SCEP CA"|認証局のCN|
|SCEPCA_ORG|"Procube"|認証局のOrganization|
|SCEPCA_COUNTRY|"JP"|認証局のCountry|

照合が完了し、bindbrokerにPUTリクエストを送る際は以下の形のURLとなる
```
{SCEP_IDM_URL}/IDManager/{SCEP_INTERFACE_NAME}/{照合されたユーザのUID}
```
また`ca.crt`と`ca.key`を保存する`SCEP_FILE_DEPOT`で指定されたフォルダは/app配下に作成され、ボリューム化することで保持できる。

### クライアント
`Dockerfile.client`をビルドすることでscepclientが実行可能なファイルを作成するイメージを構築可能。
コンテナの`/client`配下にlinuxでのみ実行可能な`scepclient-amd64`,`scepclient-arm`,`scepclient-arm64`が入っており、これをダウンロードし、`-uid`と`-secret`オプションをつけて実行することで証明書が作成できる。

**`--build-args`で指定可能な変数一覧**
| 名前 | デフォルト値|内容|
|--|--|--|
|SERVER_URL|"http://127.0.0.1:2016/scep"|SCEPサーバのURL|
|PKEY_PATH|"key.pem"|秘密鍵のファイル名|
|CERT_PATH|"cert.pem"|証明書のファイル名|
|KEY_SIZE|"2048"|秘密鍵のサイズ|
|CN|"Procube"|証明書のCN|
|OU|""|証明書のOU|
|COUNTRY|"JP"|証明書のcountry|

