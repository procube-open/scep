# SCEP

このレポジトリは、SCEP をサポートするサーバの構築と、SCEP クライアント実行ファイルのビルドを目的としています。
構築されるサーバは、通常の SCEP サーバの機能に加えて、以下の機能を持ちます。

- REST API による #PKCS12 形式ファイルの取得
- ファイルの配布
- クライアント毎の状態管理
- 証明書の認証
- 管理 API の提供
- WebUI の提供

詳細については[SERVER.md](SERVER.md)を参照して下さい。

## バージョン

テスト環境で用いた各種アプリのバージョンは以下の通りです。

```
go version go1.21.5 darwin/arm64
mysql  Ver 8.3.0 for macos14.2 on arm64 (Homebrew)
node v20.14.0
npm 10.8.1
Docker version 25.0.3, build 4debf41
```

## シークレット

SCEP サーバではクライアントが証明書を発行する際に**シークレット**という使い捨てのパスワードを使用します。
クライアントが SCEP、もしくは WebUI でシークレットを使用してクライアント証明書を発行すると、シークレットはその時点で削除されます。

![概要図](/images/overview.png)

## MySQL

SCEP サーバはクライアント、シークレット、発行済み証明書の管理に MySQL を使用します。
SCEP サーバを起動する場合は別途接続可能な MySQL サービスが必要となります。

## クライアント状態遷移

全てのクライアントは状態パラメータを持っています。
SCEP サーバは状態パラメータの値に応じて、そのクライアントが証明書を発行可能な状態かどうかを判断しています。

| 状態名    | 証明書発行可否 | 内容                                                               |
| --------- | -------------- | ------------------------------------------------------------------ |
| INACTIVE  | 不可           | クライアントが無効化されている状態                                 |
| ISSUABLE  | 可             | シークレットが作成され、新規クライアント証明書を発行可能な状態     |
| ISSUED    | 不可           | クライアント証明書が 1 つだけ有効である状態                        |
| UPDATABLE | 可             | シークレットが作成され、更新用のクライアント証明書を発行できる状態 |
| PENDING   | 不可           | クライアント証明書が 2 つ有効であり、旧証明書の失効を待つ状態      |

概要図はこちら

![ステータス遷移図](/images/status.png)

## 構築例

SCEP サーバを構築し、そこからクライアント証明書を発行するまでの流れを記述します。
Go, MySQL の導入手順は省略します。

### SCEP サーバの起動

まず、SCEP サーバの起動をします。
MySQL が`127.0.0.1:3306`で listen している状態で、以下の手順でコマンドを実行することで、SCEP サーバが起動できます。

```
make
```

```
./scepserver-opt ca -init
```

```
SCEP_DSN=root@tcp(127.0.0.1:3306)/scep?parseTime=true ./scepserver-opt
```

MySQL が listen しているアドレスが異なる場合は、SCEP_DSN 環境変数指定の部分を適宜変更して下さい。

### CLI での発行

CLI でクライアント証明書を発行する場合は、[SCEP サーバの起動](#scep-サーバの起動)が完了した状態で以下の手順に従って下さい。

#### クライアントの登録

クライアントの登録を行います。CLI で以下の curl を実行することで`"test"`という UID でクライアントの登録をすることができます。

```
curl --location 'http://localhost:3000/admin/api/client/add' \
--header 'Content-Type: application/json' \
--data '{
    "uid": "test",
    "attributes": {"hoge": "fuga"}
}'
```

#### シークレットの作成

証明書を発行するためのシークレットを作成します。CLI で以下の curl を実行することで`"test"`というクライアントに対して`"pass"`というシークレットの作成をすることができます。シークレットの有効時間は 30 分です。

```
curl --location 'http://localhost:3000/admin/api/secret/create' \
--header 'Content-Type: application/json' \
--data '{
    "secret": "pass",
    "target": "test",
    "available_period": "30m"
}'
```

#### クライアント証明書の発行

最後にクライアント証明書を発行します。最初に`make`でビルドした`scepclient-opt`というバイナリファイルを用いて、UID とシークレットを指定することで発行できます。

以下のコマンドを実行することで、`cert.pem`,`key.pem`,`csr.pem`が生成されていることが確認できます。

```
./scepclient-opt -uid=test -secret=pass
```

### ブラウザでの発行

ブラウザでクライアント証明書を発行する場合は、[SCEP サーバの起動](#scep-サーバの起動)が完了した状態で以下の手順に従って下さい。
ただし、WebUI は#PKCS12 形式での発行にのみ対応しています。

#### frontend をビルドする

WebUI は React-Admin を利用して記述されており、`frontend`フォルダがプロジェクトフォルダとなっています。以下のコマンドを順に実行することでビルドすることができます。

```
cd frontend
npm install
npm install -g vite
npm run build
```

ビルド後、ブラウザから http://localhost:3000/caweb にアクセスすることができるようになります。

#### クライアントを登録する

まず、初期に状態で表示されるクライアント一覧の右上の「**登録**」ボタンをクリックします。
すると、入力ダイアログが表示されるので UID と属性を入力して下さい。UID は一意の任意の文字列、属性は JSON でパース可能な文字列である必要があります。

![クライアント登録](/images/create_client.png)

#### シークレットを作成する

クライアント証明書発行に用いるシークレットを発行する必要があります。登録したクライアントの行をクリックすることでクライアント情報ページに移動することができ、ここでシークレットを発行することができます。

**シークレットを作成**からシークレットとなる文字列と、シークレットの有効期限を決めて「**作成**」ボタンを押して下さい。

![シークレット作成](/images/create_secret.png)

シークレットを作成すると、ステータスが**発行可能**となります。

#### 証明書を発行する

**証明書を #PKCS12 形式で発行**の欄から、先ほど作成したシークレットを入力し、任意のファイルパスワードを入力することで「**証明書発行**」ボタンが押せるようになる。これを押すことで証明書を発行し、p12 拡張子のファイルがブラウザでダウンロードされる。
