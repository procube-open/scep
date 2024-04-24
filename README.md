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
./scepserver-opt -geturl {ユーザ一覧取得インタフェースのURL} -puturl {証明書更新インタフェースのURL}

./scepclient-opt -uid {UID} -secret {Password}
```
# IDM

## ユーザ取得
指定されたUIDでIDMからユーザオブジェクトを取得する。
### インタフェース定義
IDMのインタフェース定義で参照できる必要のある属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
| uid     |  文字列  | キー属性として判定され、クライアントの照合に用いられる。"\\"が含まれていはいけない。 |
| password | 文字列| クライアントの照合に用いられる。"\\"が含まれてはいけない |

**補足**
- 環境変数 **SCEP_IDM_GET_URL** で指定されたURLにGETでJSONを取得しに行く
- `password`属性は平文化されている必要があり、`-secret`で指定された値と照合する
- フィルタ式で証明書が更新可能なもののみを取得できるようにする。

## 証明書更新
UIDとSecretによる照合が完了した後、IDMに証明書の更新をAPIで送信する。
### インタフェース定義
IDMのインタフェース定義で、参照される属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
|certIss | 日時 | 証明書発行日時を書き込む。 |
|certExp | 日時 | 証明書有効期限を書き込む。|
|certificate | 文字列 | 証明書を書き込む。 |

**補足**
- 環境変数 **SCEP_IDM_PUT_URL** で指定されたURLにPUTでJSONを送信する。
- インターフェ-ス定義で上記属性アクセス可能となっている必要がある。

## 失効証明書取得
失効された証明書をIDMから取得し、CRLを作成する。
### インタフェース定義
IDMのインタフェース定義で、参照される属性名は以下の通り。

| 属性名 | IDMでの型定義 | SCEPサーバ内処理 |
|--------|----|--------------|
|certificate | 文字列 | 証明書をパースしてシリアルをCRLに追加する |

**補足**
- 環境変数 **SCEPCA_IDM_CRL_URL** で指定されたURLにJSONを取得しに行く

### CRL更新
CRLの更新はサーバ内で`/app/scepserver-opt ca -create-crl`が実行された際に行われる。
環境変数**SCEPCA_IDM_CRL_URL**を設定する、もしくは`-crlurl`を指定する必要がある。

CRLの有効期限は作成されてから24時間であり、日次バッチ処理が必要。

**SCEPCA_IDM_CRL_URL**で取得した証明書と、depotフォルダ配下の`index.txt`の最初の文字が`R`となっている証明書のシリアルを合わせたものでCRLを作成する。
# サーバ構築

`make`コマンド、もしくは`Dockerfile`をビルドすることで構築が可能

## 環境変数一覧

| 名前 | デフォルト値|内容|
|--|--|--|
|**SCEP_IDM_GET_URL**|""|証明書を更新したいユーザ一覧を取得するインタフェースのURL|
|**SCEP_IDM_PUT_URL**|""|証明書を更新するインタフェースのURL|
|**SCEP_IDM_USERS_URL**|""|`/userObject`APIで検証後に取得するインターフェースのURL|
|SCEP_HTTP_LISTEN_PORT|"3000"|サーバのポート番号|
|SCEP_FILE_DEPOT|"idm-depot"|depotフォルダのパス(/app配下)|
|SCEP_CERT_VALID|"365"|証明書の有効期限|
|SCEP_IDM_HEADER0|""|IDM呼び出し時に追加でヘッダーをつけることができる。変数を`:`で区切り、一つ目をキー、二つ目を値として扱う。値の例:`HTTP_REMOTEUSER:IDM_ADMIN`|
|SCEP_IDM_HEADER1|""|`SCEP_IDM_HEADER0`と同様。|
|**SCEPCA_IDM_CRL_URL**|""|失効する証明書一覧を取得するインタフェースのURL|
|SCEPCA_YEARS|"10"|ca.crtの有効期間(年)|
|SCEPCA_KEY_SIZE|"4096"|ca.keyのサイズ|
|SCEPCA_CN|"Procube SCEP CA"|認証局のCN|
|SCEPCA_ORG|"Procube"|認証局のOrganization|
|SCEPCA_ORG_UNIT|""|認証局のOrganization Unit|
|SCEPCA_COUNTRY|"JP"|認証局のCountry|

## depotフォルダ
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

## クライアント実行ファイル作成
コンテナ内で以下の変数を指定して`/app/cmd/scepclient.go`をビルドすることでクライアント実行ファイルを作成することができる。
| 名前 | デフォルト値|内容|
|--|--|--|
|version|"unknown"|バージョン情報|
|flServerURL|"http://127.0.0.1:3000/scep"|接続するSCEPサーバのURL。`/scep`までパス指定が必要。|
|flPKeyFileName|"key.pem"|秘密鍵のファイル名|
|flCertFileName|"cert.pem"|証明書のファイル名|
|flKeySize|"2048"|秘密鍵のサイズ|
|flOrg|"Procube"|証明書のORG|
|flOU|""|証明書のOU|
|flCountry|"JP"|証明書のCountry|

生成される証明書のCNは`-uid`で指定された値で固定される。

### テンプレート

```
/app # GOOS=linux GOARCH=amd64 \
  go build -ldflags "\
  -X main.flServerURL=http://127.0.0.1:3000/scep \
  -X main.flPKeyFileName=key.pem \
  -X main.flCertFileName=cert.pem \
  -X main.flKeySize=2048 \
  -X main.flOrg=Procube \
  -X main.flOU= \
  -X main.flCountry=JP \
  " -o /download/scepclient-amd64 ./cmd/scepclient
```
`GOOS`,`GOARCH`オプションの値も実行される環境を想定して適宜設定する必要がある。
また、`-o`オプションの値でパスを指定できる。

# クライアント

## REST API
`/scep`は`operation`クエリによって内容が異なるので含めて表記している。
| パス | メソッド|内容|
|--|--|--|
|/caweb|`GET`|webページを表示する。`uid`と`secret`クエリを指定することで初期値を設定できる。|
|/caweb/static/`:script`/`:filename`|`GET`|webページを表示するのに使う|
|/caweb/manifest.json|`GET`|webページを表示するのに使う|
|/caweb/favicon.ico|`GET`|webページを表示するのに使う|
|/caweb/logo192.png|`GET`|webページを表示するのに使う|
|/caweb/logo512.png|`GET`|webページを表示するのに使う|
|/userObject|`GET`|`X-Mtls-Clientcert`ヘッダーに添付されているクライアント証明書（PEM形式の証明書をURLエンコードした文字列）を読み込んで署名検証する。検証が成功すれば添付された証明書のCNで`${SCEP_IDM_USERS_URL}/${CN}`の結果を返す。|
|/download/`:filename`|`GET`|`/download`配下に置かれたファイルをダウンロードする。[クライアント実行ファイル](#クライアント実行ファイル作成)で作成したファイルをここに置くことでユーザに配布できる。|
|/scep?operation=GetCACaps|`GET`|linux実行ファイルで使う。認証局の情報を取得する。|
|/scep?operation=GetCACert|`GET`|linux実行ファイルで使う。認証局の証明書を取得する。|
|/scep?operation=PKIOperation|`POST`|linux実行ファイルで使う。CSRを認証する。|
|/scep?operation=GetCRL|`GET`|CRLを取得する。|
|/scep?operation=CreatePKCS12|`POST`|PKCS#12形式ファイルを取得する。|

## linux
linux実行ファイルをダウンロードし、それを実行することで証明書ファイル群が生成される。
```
curl -O {URL}/download/scepclient-amd64

./scepclient -uid {UID} -secret {password}
```

## ブラウザ利用
webページにアクセスし、ダウンロードボタンを押すことでPKCS#12形式でファイルをダウンロードできる。
クエリで`http://localhost:3000/caweb?uid=test&secret=pass`などとすることで`uid`と`secret`の初期値を設定可能。
また、PKCS#12ファイルのパスワードを設定できる。

**補足**:
PKCS#12形式ファイル作成時には`/app/scepclient-opt`を実行し、生成された証明書をPKCS#12形式に変換して作成している。

なので、ブラウザ利用で生成される証明書の鍵サイズやOU情報などを書き換えたい場合は[クライアント実行ファイル作成](#クライアント実行ファイル作成)で`/app/scepclient-opt`を上書きビルドする必要がある。(flPKeyFileNameやflCertFileNameは指定すると正常に生成できなくなるので注意)
