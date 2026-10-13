/**
 * Static HTML sign-in page served to unauthenticated browser navigations.
 *
 * The page carries no scripts and no external assets: a plain form re-issues
 * the root request with the pasted launch token, landing on the existing
 * token-to-cookie exchange in BrowserAuth. Non-browser requests (curl, API
 * clients, HEAD probes) keep receiving the machine-readable 401 body.
 */

const PAGE_STYLES = `
  :root { color-scheme: dark }
  * { margin: 0; padding: 0; box-sizing: border-box }
  body {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background: radial-gradient(1200px 800px at 20% -10%, #1b2a6b 0%, transparent 55%),
                radial-gradient(1000px 700px at 110% 110%, #3b1d5e 0%, transparent 50%),
                #0b0e17;
    color: #e8eaf2;
  }
  .card {
    width: min(400px, calc(100vw - 48px));
    padding: 40px 36px 32px;
    border-radius: 16px;
    background: rgba(22, 26, 40, 0.72);
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.45);
    backdrop-filter: blur(14px);
  }
  .logo {
    font-size: 28px;
    font-weight: 700;
    letter-spacing: 0.04em;
  }
  .logo span { color: #4d6bfe }
  .tagline {
    margin-top: 6px;
    font-size: 14px;
    color: #9aa3b8;
  }
  form { margin-top: 28px }
  label {
    display: block;
    font-size: 13px;
    font-weight: 600;
    color: #c2c9da;
    margin-bottom: 8px;
  }
  input {
    width: 100%;
    padding: 12px 14px;
    border-radius: 10px;
    border: 1px solid rgba(255, 255, 255, 0.14);
    background: rgba(11, 14, 23, 0.65);
    color: #e8eaf2;
    font-size: 15px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    outline: none;
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }
  input:focus {
    border-color: #4d6bfe;
    box-shadow: 0 0 0 3px rgba(77, 107, 254, 0.25);
  }
  button {
    width: 100%;
    margin-top: 18px;
    padding: 12px 14px;
    border: none;
    border-radius: 10px;
    background: linear-gradient(135deg, #4d6bfe, #6a4dfb);
    color: #fff;
    font-size: 15px;
    font-weight: 600;
    cursor: pointer;
    transition: filter 0.15s ease, transform 0.05s ease;
  }
  button:hover { filter: brightness(1.1) }
  button:active { transform: translateY(1px) }
  .error {
    margin-top: 16px;
    padding: 10px 12px;
    border-radius: 8px;
    border: 1px solid rgba(244, 63, 94, 0.35);
    background: rgba(244, 63, 94, 0.12);
    color: #fda4af;
    font-size: 13px;
  }
  .hint {
    margin-top: 22px;
    font-size: 12px;
    line-height: 1.6;
    color: #6f7890;
  }
  .hint code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    color: #9aa3b8;
  }
`

/**
 * Render the sign-in page for browser navigations.
 * @param options - rendering options; `invalidToken: true` adds the retry notice after a
 * failed exchange; `staticToken: true` points the hint at the deployment-configured token instead of the startup log.
 * @returns complete standalone HTML document.
 */
export function renderLoginPage(options: { invalidToken?: boolean; staticToken?: boolean } = {}): string {
  const errorHtml = options.invalidToken === true
    ? '<p class="error">Invalid token. Check the token and try again.</p>'
    : ''
  const hintHtml = options.staticToken === true
    ? '<p class="hint">Enter the access token configured for this deployment (DSH_WEB_TOKEN).</p>'
    : `<p class="hint">The token is printed once per boot in the service log:<br>
      <code>docker logs &lt;container&gt; 2&gt;&amp;1 | grep -o 'token=.*'</code></p>`
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>dsh · Sign in</title>
<style>${PAGE_STYLES}</style>
</head>
<body>
  <main class="card">
    <h1 class="logo">d<span>sh</span></h1>
    <p class="tagline">DeepSeek Harness · web console</p>
    <form method="get">
      <label for="token">Access token</label>
      <input id="token" name="token" type="password" autocomplete="off" autofocus required>
      <button type="submit">Sign in</button>
      ${errorHtml}
    </form>
    ${hintHtml}
  </main>
</body>
</html>
`
}
