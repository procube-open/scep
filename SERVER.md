# 目次

- [目次](#目次)
- [環境変数一覧](#環境変数一覧)
  - [SCEP\_DSN](#scep_dsn)
  - [フック処理](#フック処理)
    - [サーバ起動前](#サーバ起動前)
    - [クライアント作成後](#クライアント作成後)
    - [クライアント証明書発行後](#クライアント証明書発行後)
- [クライアント実行ファイルをビルド](#クライアント実行ファイルをビルド)
  - [テンプレート](#テンプレート)
- [バッチ処理](#バッチ処理)
    - [証明書の失効日時確認](#証明書の失効日時確認)
    - [証明書の有効期限確認](#証明書の有効期限確認)
    - [シークレットの有効期限確認](#シークレットの有効期限確認)
      - [補足](#補足)
- [REST API](#rest-api)
  - [SCEP](#scep)
    - [SCEP Operation](#scep-operation)
  - [ユーザ API](#ユーザ-api)
    - [ファイルダウンロード(GET `/api/download/{path}`)](#ファイルダウンロードget-apidownloadpath)
      - [レスポンス](#レスポンス)
    - [ディレクトリ内取得(GET `/api/files/{path}`)](#ディレクトリ内取得get-apifilespath)
    - [証明書検証(GET `/api/cert/verify`)](#証明書検証get-apicertverify)
      - [検証内容](#検証内容)
    - [#PKCS12 形式で証明書発行(POST `/api/cert/pkcs12`)](#pkcs12-形式で証明書発行post-apicertpkcs12)
      - [リクエスト](#リクエスト)
      - [レスポンス](#レスポンス-1)
    - [証明書一覧取得(GET `/api/cert/list/{CN}`)](#証明書一覧取得get-apicertlistcn)
    - [クライアント一覧取得(GET `/api/client`)](#クライアント一覧取得get-apiclient)
    - [クライアント単体取得(GET `/api/client/{CN}`)](#クライアント単体取得get-apiclientcn)
  - [管理者 API](#管理者-api)
    - [ping(GET `/admin/api/ping`)](#pingget-adminapiping)
    - [クライアント追加(POST `/admin/api/client/add`)](#クライアント追加post-adminapiclientadd)
      - [リクエスト](#リクエスト-1)
    - [クライアント失効(POST `/admin/api/client/revoke`)](#クライアント失効post-adminapiclientrevoke)
      - [リクエスト](#リクエスト-2)
    - [クライアントアップデート(PUT `/admin/api/client/update`)](#クライアントアップデートput-adminapiclientupdate)
      - [リクエスト](#リクエスト-3)
    - [シークレット作成(POST `/admin/api/secret/create`)](#シークレット作成post-adminapisecretcreate)
      - [リクエスト](#リクエスト-4)
    - [シークレット取得(GET `/admin/api/secret/get/{CN}`)](#シークレット取得get-adminapisecretgetcn)
      - [レスポンス](#レスポンス-2)

# 環境変数一覧

SCEP サーバは以下の環境変数を参照します。
| 名前 | デフォルト値 | 内容 |
| --------------------- | ----------------- | ------------------------------------ |
| **SCEP_DSN** | "" | 参照する MySQL の DSN(必須) |
| SCEP_HTTP_LISTEN_PORT | "3000" | サーバのポート番号 |
| SCEP_FILE_DEPOT | "ca-certs" | CA 証明書を保管するフォルダのパス |
| SCEP_DOWNLOAD_PATH | "download" | 配布するファイルを置くフォルダのパス |
| SCEP_TICKER | "24h" | 証明書の有効期限を確認する周期 |
| SCEP_CERT_VALID | "365" | 証明書の有効期限 |
| SCEP_INITIAL_SCRIPT | "" | サーバ起動時に実行されるシェルスクリプトのパス |
| SCEP_ADD_CLIENT_SCRIPT | "" | クライアント作成時に実行されるシェルスクリプトのパス |
| SCEP_SIGN_SCRIPT | "" | クライアント証明書発行時に実行されるシェルスクリプトのパス |
| SCEP_SCRIPT_TIME_FORMAT | "2006-01-02 15:04:05" | シェルスクリプトに渡される日時のフォーマット |
| SCEPCA_YEARS | "10" | ca.crt の有効期間(年) |
| SCEPCA_KEY_SIZE | "4096" | ca.key のサイズ |
| SCEPCA_CN | "Procube SCEP CA" | 認証局の CN |
| SCEPCA_ORG | "Procube" | 認証局の Organization |
| SCEPCA_ORG_UNIT | "" | 認証局の Organization Unit |
| SCEPCA_COUNTRY | "JP" | 認証局の Country |

## SCEP_DSN

MySQL に接続するために設定必須の環境変数です。
記法は[こちら](https://github.com/go-sql-driver/mysql?tab=readme-ov-file#dsn-data-source-name)を参考にして下さい。
また、接続設定で日本時間にすることを推奨します。以下に`127.0.0.1:3306`で MySQL の`certs`というデータベースに root 接続する際の設定例を記述します。

```
SCEP_DSN="root@tcp(127.0.0.1:3306)/certs?parseTime=true&loc=Asia%2FTokyo"
```

## フック処理

以下の時点で環境変数で設定したパスのシェルスクリプトを実行するフック処理を追加することができます。

- サーバ起動前
- クライアント作成後
- クライアント証明書発行後

また、設定されていない場合は何も実行されません。

### サーバ起動前

サーバ起動前に`SCEP_INITIAL_SCRIPT`で設定されたパスのシェルスクリプトを実行します。
参照可能な引数はありません。

### クライアント作成後

クライアント作成後に`SCEP_ADD_CLIENT_SCRIPT`で設定されたパスのシェルスクリプトを実行します。
`$UID`で作成したクライアント ID を参照できます。

### クライアント証明書発行後

クライアント証明書発行後に`SCEP_SIGN_SCRIPT`で設定されたパスのシェルスクリプトを実行します。
`$CN`でCN、`$NOT_BEFORE`で発行日時、`$NOT_AFTER`で有効期限が参照できます。
また、`NOT_BEFORE`と`NOT_AFTER`のフォーマットは`SCEP_SCRIPT_TIME_FORMAT`環境変数を参照します。
`SCEP_SCRIPT_TIME_FORMAT`は「2006年1月2日15時4分5秒 アメリカ山地標準時MST(GMT-0700)」を表す時刻で記述して下さい。
詳細については[こちら](https://pkg.go.dev/time#Time.Format)を参照して下さい。

# クライアント実行ファイルをビルド

コンテナ内で以下の変数を指定して`/app/cmd/scepclient.go`をビルドすることで、クライアント実行ファイルを作成することができます。

| 名前           | デフォルト値                 | 内容                       |
| -------------- | ---------------------------- | -------------------------- |
| version        | "unknown"                    | バージョン情報             |
| flServerURL    | "http://127.0.0.1:3000/scep" | 接続する SCEP サーバの URL |
| flPKeyFileName | "key.pem"                    | 秘密鍵のファイル名         |
| flCertFileName | "cert.pem"                   | 証明書のファイル名         |
| flKeySize      | "2048"                       | 秘密鍵のサイズ             |
| flOrg          | "Procube"                    | 証明書の ORG               |
| flOU           | ""                           | 証明書の OU                |
| flCountry      | "JP"                         | 証明書の Country           |
| flDNSName      | ""                           | 証明書の DNS               |

生成される証明書の CN は`-uid`で指定された値で固定されています。

またビルドしたクライアント実行ファイルを配布したい場合は、`SCEP_DOWNLOAD_PATH`環境変数で指定したパス配下に置くことで[ダウンロード API](#ファイルダウンロードget-apidownloadpath)からダウンロードすることができるようになります。

## テンプレート

以下のテンプレートを参考にクライアント実行ファイルをビルドして下さい。

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
  -X main.flDNSName= \
  " -o ./download/scepclient-amd64 ./cmd/scepclient
```

`GOOS`,`GOARCH`オプションの値も実行される環境を想定して適宜設定する必要があります。
また、`-o`オプションの値でビルド先のパスを指定することもできます。

# バッチ処理

証明書の有効期限切れとシークレットの削除漏れの確認のために、SCEP サーバではバッチ処理を行っています。周期は`SCEP_TICKER`環境変数を参照しており、Golang の [time.ParseDuration](https://pkg.go.dev/time#ParseDuration)でパース可能な形で指定して下さい。

処理内容としては、具体的に以下の処理を行っています。

### 証明書の失効日時確認

クライアントの状態が`PENDING`であり、かつ証明書の失効日時が現在日時以前の日時のものが存在した場合、クライアントを`ISSUED`状態にし、旧証明書を無効にします。

### 証明書の有効期限確認

クライアントの状態が`ISSUED`であり、かつ証明書の有効期限が現在日時以前の場合、クライアントを`INACTIVE`状態にし、証明書を無効にします。

### シークレットの有効期限確認

シークレットの有効期限が有効期限が現在日時以前のものが存在した場合、そのシークレットを削除します。

#### 補足

シークレットは作成された段階で、有効期限までのタイマーを起動します。
タイマーが発火すると、シークレットが削除されます。
しかし、タイマーは発火するまでにサーバの再起動が行われると削除されてしまいます。
上記の[シークレット有効期限確認](#シークレットの有効期限確認)はこの場合のケアを目的として導入されています。

# REST API

対応する REST API を記述します。

## SCEP

`/scep`パスでは、基本的な SCEP オペレーションをサポートしています。`operation`クエリで各オペレーションを指定することができます。

### SCEP Operation

SCEP サーバは以下のオペレーションをサポートしています。

| Operation    | メソッド | 内容                                                     |
| ------------ | -------- | -------------------------------------------------------- |
| GetCACaps    | GET      | サポートする機能のリストを返す                           |
| GetCACert    | GET      | CA 証明書を DER 形式で返す                               |
| PKIOperation | POST     | CSR を受け取り、ポリシーに従って検証し、証明書を発行する |
| GetCRL       | GET      | CRL を DER 形式で返す                                    |

## ユーザ API

エンドユーザが利用可能な API を`/api`で提供します。

### ファイルダウンロード(GET `/api/download/{path}`)

`/api/download`パスでは、ファイルのダウンロードを行うことができます。

#### レスポンス

`{path}`で示された部分のパスで`SCEP_DOWNLOAD_PATH`環境変数配下のファイルを参照します。
参照されたファイルのデータをレスポンスボディーに入れて返却します。

### ディレクトリ内取得(GET `/api/files/{path}`)

`/api/files/{path}`ではダウンロード可能なファイルとディレクトリの一覧を取得することができます
`{path}`はディレクトリを指定し、その配下に存在するファイルとディレクトリのみが取得できます。

### 証明書検証(GET `/api/cert/verify`)

`/api/cert/verify`では貼付されたクライアント証明書の検証を行い、有効な証明書であった場合は対応するクライアントの情報を返します。検証するクライアント証明書は URL エンコードして、リクエストヘッダの`X-Mtls-Clientcert`につけて送信して下さい。

#### 検証内容

以下の検証を通過した場合のみクライアントを取得できます。

- `X-Mtls-Clientcert`ヘッダが存在すること
- `X-Mtls-Clientcert`ヘッダの値が URL デコード可能であること
- URL デコードしたものが証明書としてパースできること
- 証明書の有効期限が現在時刻と照らし合わせて有効であること
- CA 証明書を使いクライアント証明書を検証し、その結果が有効であること
- クライアント証明書のシリアル番号が失効されていないこと
- 対応するクライアントが存在すること

### #PKCS12 形式で証明書発行(POST `/api/cert/pkcs12`)

`/api/cert/pkcs12`では #PKCS12 形式でクライアント証明書を発行することができます。

この API を用いて証明書を発行する場合、発行される証明書の Org や OU は`./scepclient-opt`の形式に依存します。これを編集したい場合は[クライアント実行ファイルをビルド](#クライアント実行ファイルをビルド)を参考に`./scepclient-opt`を上書きビルドして下さい。

#### リクエスト

リクエストに関して、`Content-Type`ヘッダは`application/json`として、リクエストボディは JSON で以下のパラメータを入力して下さい。

- uid
- secret
- password

全て文字列で、0 文字以上の値を入力して下さい。

#### レスポンス

レスポンスに至るまでの内部処理の流れは以下の通りです。

1. JSON で指定された uid と secret を用いて`./scepclient-opt`ファイルを実行
2. CA 証明書と、1.で生成された`cert.pem`,`key.pem`を用いて LegacyDES 方式で#PKCS12 形式にエンコード
3. 1.で生成された`cert.pem`,`key.pem`,`csr.pem`を削除
4. 2.でエンコードした証明書をレスポンスボディに入れて返す。

### 証明書一覧取得(GET `/api/cert/list/{CN}`)

`/api/cert/list/{CN}`では発行された証明書のうち、CN が`{CN}`で指定されたものと一致するものを返します。

### クライアント一覧取得(GET `/api/client`)

`/api/client`では登録されているクライアントの一覧を取得することができます。
存在しない場合は`null`を返します。

### クライアント単体取得(GET `/api/client/{CN}`)

`/api/client/{CN}`では`{CN}`で指定された UID を持つクライアントを単体取得することができます。
存在しない場合は`null`を返します。

## 管理者 API

管理者用の API を`/admin/api`で提供します。

### ping(GET `/admin/api/ping`)

`/admin/api/ping`では無条件で`pong`という文字列を返します。WebUI で`/admin`パスが有効かどうか調べるために用います。

### クライアント追加(POST `/admin/api/client/add`)

`/admin/api/client/add`ではクライアントを登録することができます。成功した場合はレスポンスは空で、初期ステータスは"INACTIVE"として登録されます。

#### リクエスト

リクエストに関して、`Content-Type`ヘッダは`application/json`として、リクエストボディは JSON で以下のパラメータを入力して下さい。

- uid
- attributes

uid は文字列で必須で、attributes はオブジェクト型であれば任意に設定でき、かつ SCEP サーバでこのパラメータを参照して特定の操作を行うことはありません。attributes パラメータが設定されていない場合は"{}"として登録されます。

### クライアント失効(POST `/admin/api/client/revoke`)

`/admin/api/client/revoke`では指定されたクライアントを強制的に`INACTIVE`状態に遷移させます。
それに加え、指定されたクライアントの状態によって異なる動作をします。

**INACTIVE**: エラーを返します。

**ISSUABLE**: 指定されたクライアントのシークレットを削除します。

**ISSUED**: 有効な証明書を失効させます。

**UPDATABLE**: 有効な証明書を失効させ、シークレットも削除します。

**PENDING**: 2 つの有効な証明書をどちらも失効させます。

#### リクエスト

リクエストに関して、`Content-Type`ヘッダは`application/json`として、リクエストボディは JSON で以下のパラメータを入力して下さい。

- uid

パラメータは uid のみで、失効させたいクライアントの uid を入力して下さい。

### クライアントアップデート(PUT `/admin/api/client/update`)

`/admin/api/client/update`では指定されたクライアントの`attributes`パラメータの上書きをすることができます。

#### リクエスト

リクエストに関して、`Content-Type`ヘッダは`application/json`として、リクエストボディは JSON で以下のパラメータを入力して下さい。

- uid
- attributes

uid で指定した値をもつクライアントの attributes が指定したものに置き換えられます。

### シークレット作成(POST `/admin/api/secret/create`)

`/admin/api/secret/create`では指定したクライアントのシークレットを作成することができます。

#### リクエスト

リクエストに関して、`Content-Type`ヘッダは`application/json`として、リクエストボディは JSON で以下のパラメータを入力して下さい。

- target
- secret
- available_period
- pending_period

パラメータは全て文字列で、target で指定された uid のクライアントに secret で指定された文字列でシークレットが作成されます。

**available_period**はシークレットが作成されてから削除されるまでの期間を表しています。

**pending_period**は ISSUED から UPDATABLE への状態遷移を起こすシークレット作成の場合のみ有効であり、シークレットを用いて証明書発行後、旧証明書を失効するまでの期間を表しています。

また、available_period と pending_period の期間指定は Golang の [time.ParseDuration](https://pkg.go.dev/time#ParseDuration)でパース可能な形でして下さい。

以下の図は available_period と pending_period がどの部分の期間を表しているかの概略図です。

![期間説明](/images/status_for_secret.png)

### シークレット取得(GET `/admin/api/secret/get/{CN}`)

`/admin/api/secret/get/{CN}`では`{CN}`で指定された UID を持つクライアントのシークレットを取得します。

#### レスポンス

レスポンスに関して、`Content-Type`ヘッダは`application/json`として、レスポンスボディは JSON で以下のパラメータが存在するものが返されます。

- secret
- type
- delete_at
- pending_period

secret はシークレットの文字列を表しており、type は INACTIVE から ISSUABLE への変化なら**ACTIVATE**が、ISSUED から UPDATABLE への変化なら**UPDATE**という文字列が入ります。

delete_at は [シークレット作成](#リクエスト-4) 時の available_period から計算された UTC 時刻が入っており、pending_period は作成時のそのままの値が入っています。
