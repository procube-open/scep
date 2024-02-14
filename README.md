# SCEPサーバ
IDMと連携可能なSCEPサーバを構築する。

- クライアント証明書を取得可能なlinux実行ファイルの配布
- CRLファイルの作成、および配布
- REST APIによるPKCS#12形式ファイルの取得
## サンプル
ローカル環境で構築しテストする場合、Golangを導入し以下のコマンドを実行することで`cert.pem`,`key.pem`,`csr.pem`の三種類のファイルが作られることが確認できる。
```
make

./scepserver-opt ca -init
./scepserver-opt -idmurl {JSONを取得できるURL}

./scepclient-opt -uid {UID} -secret {Password}
```
※ `-idmurl`オプションは環境変数で**SCEP_IDM_CERT_URL**を指定するのと同じ動作
# IDM

## ユーザ取得

### クラス定義
IDMのクラス定義で、参照される属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
| uid     |  文字列  | キー属性として判定され、クライアントの照合に用いられる。"\\"が含まれていはいけない。 |
| password | 文字列| クライアントの照合に用いられる。"\\"が含まれてはいけない |
| certIss | 日時 | 照合に成功した場合は証明書発行日時を書き込む。 |
|certExp | 日時 | 照合に成功した場合は証明書有効期限を書き込む。|
|certificate | 文字列 | 照合に成功した場合は証明書を書き込む。 |

### インターフェース定義
- 環境変数 **SCEP_IDM_CERT_URL** で指定されたURLにJSONを取得しに行く
- [上記の属性](#クラス定義)がインターフェ-ス定義でアクセス可能となっている必要がある。
- `password`属性は平文化されている必要がある。
- フィルタ式で証明書が更新可能なもののみを取得できるようにする。

## 失効証明書取得

### クラス定義
IDMのクラス定義で、参照される属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
|certificate | 文字列 | 証明書をパースしてシリアルをCRLに追加する |

### インターフェース定義
- 環境変数 **SCEPCA_IDM_CRL_URL** で指定されたURLにJSONを取得しに行く
- [上記の属性](#クラス定義)がインターフェ-ス定義で読み取り可能となっている必要がある。

### CRL更新
CRLの更新はサーバ内で`/app/scepclient-opt ca -create-crl`が実行された際に行われる。
環境変数**SCEPCA_IDM_CRL_URL**を設定する、もしくは`-idmurl`を指定する必要がある。

CRLの有効期限は作成されてから24時間であり、日時バッチ処理が必要。

# Docker

`Dockerfile`をビルドすることで構築が可能

**環境変数一覧**
| 名前 | デフォルト値|内容|
|--|--|--|
|**SCEP_IDM_CERT_URL**|""|証明書を更新したいユーザ一覧を取得するインターフェースのURL|
|SCEP_HTTP_LISTEN_PORT|"2016"|サーバのポート番号|
|SCEP_FILE_DEPOT|"idm-depot"|depotフォルダのパス(/app配下)|
|SCEP_CERT_VALID|"365"|証明書の有効期限|
|**SCEPCA_IDM_CRL_URL**|""|失効する証明書一覧を取得するインターフェースのURL|
|SCEPCA_YEARS|"10"|ca.crtの有効期間(年)|
|SCEPCA_KEY_SIZE|"4096"|ca.keyのサイズ|
|SCEPCA_CN|"Procube SCEP CA"|認証局のCN|
|SCEPCA_ORG|"Procube"|認証局のOrganization|
|SCEPCA_ORG_UNIT|""|認証局のOrganization Unit|
|SCEPCA_COUNTRY|"JP"|認証局のCountry|

linux実行ファイルの変数は`--build-args`で指定し、以下を参照してビルドされる。

**`--build-args`で指定可能な変数一覧**
| 名前 | デフォルト値|内容|
|--|--|--|
|SERVER_URL|"http://127.0.0.1:2016/scep"|SCEPサーバのURL|
|PKEY_FILENAME|"key.pem"|秘密鍵のファイル名|
|CERT_FILENAME|"cert.pem"|証明書のファイル名|
|KEY_SIZE|"2048"|秘密鍵のサイズ|
|ORG|""|証明書のORG|
|OU|""|証明書のOU|
|COUNTRY|"JP"|証明書のcountry|

CNはuidで指定された値で固定される。

### depotフォルダ
`/app/scepserver-opt ca -init`を実行された時にdepotフォルダが生成される。(Dockerfile内で実行され、デフォルトだと`/app/idm-depot`)
ボリューム化することで内容が保持できる。

depotフォルダが保持するファイル一覧は以下の通り
| ファイル名 |内容|
|--|--|
|ca.crt|認証局の証明書|
|ca.key|認証局の秘密鍵|
|index.txt|発行日時や失効された日時を記録したもの|
|serial|最後のシリアルナンバーを記録したもの|
|ca.crl|CRLファイル|

# REST API
`/scep`は`operation`クエリによって内容が異なるので含めて表記している。
| パス | メソッド|内容|
|--|--|--|
|/|`GET`|webページを表示する。`uid`と`secret`クエリを指定することで初期値を設定できる。|
|/static/`:script`/`:filename`|`GET`|webページを表示するのに使う|
|/manifest.json|`GET`|webページを表示するのに使う|
|/favicon.ico|`GET`|webページを表示するのに使う|
|/logo192.png|`GET`|webページを表示するのに使う|
|/logo512.png|`GET`|webページを表示するのに使う|
|/download/`:filename`|`GET`|`/client`配下に置かれたファイルをダウンロードする。`scepclient-amd64`,`scepclient-arm`,`scepclient-arm64`が指定可能。|
|/scep?operation=GetCACaps|`GET`|linux実行ファイルで使う。認証局の情報を取得する。|
|/scep?operation=GetCACert|`GET`|linux実行ファイルで使う。認証局の証明書を取得する。|
|/scep?operation=PKIOperation|`POST`|linux実行ファイルで使う。CSRを認証する。|
|/scep?operation=GetCRL|`GET`|CRLを取得する。|
|/scep?operation=CreatePKCS12|`POST`|PKCS#12形式ファイルを取得する。|

# クライアント

### linux
linux実行ファイルをダウンロードし、それを実行することで証明書ファイル群が生成される。
```
curl {URL}/download/scepclient-amd64 > scepclient

./scepclient -uid {UID} -secret {password}
```

### ブラウザ利用
webページにアクセスし、ダウンロードボタンを押すことでPKCS#12形式でファイルをダウンロードできる。
クエリで`http://localhost:2016/?uid=test&secret=pass`とすることで初期値を設定可能。
また、PKCS#12ファイルのパスワードを設定できる。
