import React from 'react';
import './App.css';
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'
import { faEye, faEyeSlash } from '@fortawesome/free-solid-svg-icons'

function App() {
  const queryParameters = new URLSearchParams(window.location.search)
  const uid = queryParameters.get("uid")
  const secret = queryParameters.get("secret")
  const [isRevealPassword, setIsRevealPassword] = React.useState(false);

  function download(blob, filename) {
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.style.display = 'none';
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    window.URL.revokeObjectURL(url);
  }

  const togglePassword = () => {
    setIsRevealPassword((prevState) => !prevState);
  }

  async function handleSubmit(e) {
    e.preventDefault();

    const form = e.target;
    const formData = new FormData(form);
    const formJson = Object.fromEntries(formData.entries());
    if (!formJson.uid || formJson.uid == "") return alert("UIDを設定してください。")
    if (!formJson.secret || formJson.secret == "") return alert("Secretを設定してください。")
    if (!formJson.password || formJson.password == "") return alert("ファイルパスワードを設定してください。")
    const res = await fetch('/scep?operation=CreatePKCS12', { method: "POST", body: JSON.stringify(formJson) });
    if (res.status === 200) {
      const blob = await res.blob()
      download(blob, formJson.uid + ".p12")
    }
    else {
      alert(res.status + " " + await res.text())
    }
    
  }

  return (
    <div className="Form">
      <form method="post" onSubmit={handleSubmit}>
        <label>
          PKCS#12 形式でクライアント証明書をダウンロード
        </label>
        <hr />
        <label className="Uid">
          UID: <input name="uid" defaultValue={uid} />
        </label>
        <label className="Secret">
          Secret: <input name="secret" defaultValue={secret} />
        </label>
        <hr />
        <label className="Password">
          ファイルパスワード:
          <input name="password" type={isRevealPassword ? 'text' : 'password'} />
          <span
            onClick={togglePassword}
            role="presentation"
          >
            {isRevealPassword ? (
              <FontAwesomeIcon className="Toggle-button" icon={faEye} />
            ) : (
              <FontAwesomeIcon className="Toggle-button" icon={faEyeSlash} />
            )}
          </span>
        </label>
        <hr />
        <button type="submit">ダウンロード</button>
      </form>
    </div>
  );
}

export default App;
