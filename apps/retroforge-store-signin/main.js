// retroforge-store-signin — GOG's or Epic's own sign-in page in one full-screen window, and the code
// it ends with on stdout. Electron (Chromium) and not WebKit or Servo: Google refuses its sign-in in
// browsers it takes for embedded ones, and Epic's "Sign in with Google" is a must; Chromium-based
// Steam passes on NovaDeck.
//
//   electron --ozone-platform=x11 <this folder> <gog|epic>
//
// Exit 0 with one JSON line on stdout, {"store": ..., "code": ...}; 1 when the window was closed or
// 15 minutes passed without a code; 2 for a bad invocation. Everything else goes to stderr.
//
// NOT A BROWSER. No address bar, no menu, no downloads, no permission prompts. The top frame goes only
// to the store's own hosts and the sign-in providers the store offers (SIGN_IN_HOSTS); a navigation
// anywhere else is refused and logged, so a provider missing from the list shows up in the log.
// Subresources (captchas, scripts, fonts) load from anywhere, as the pages need them.
//
// IDENTITY. Chromium's own user agent: Electron's default adds "Electron/<v>" and the app's name,
// which is what an embedded-browser check looks for.
//
// NOTHING KEPT. The page's cookies and storage live in memory (a partition without "persist:"), and
// Chromium's own folder is a temporary one removed at exit: the next sign-in starts signed out.
'use strict';

const { app, BrowserWindow, Menu, session } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');

const TIMEOUT_MS = 15 * 60 * 1000;  // as the store helper's sign-in
const RETRY_MS = 3000;

// The providers behind the stores' "Sign in with ..." buttons.
const SIGN_IN_HOSTS = [
  'google.com', 'accounts.google.com', 'gstatic.com',
  'apple.com', 'live.com', 'microsoftonline.com', 'xbox.com',
  'facebook.com', 'steamcommunity.com', 'steampowered.com',
  'nintendo.com', 'sony.com', 'playstation.com',
];

// Epic's code page: the redirect legendary's own login (legendary.gl/epiclogin) ends on, for the
// launcher's client id, which `legendary auth --code` exchanges.
const EPIC_REDIRECT = 'https://www.epicgames.com/id/api/redirect?clientId=34a02cf8f4414e29b15921876da36f9a&responseType=code';

const STORES = {
  gog: {
    start: 'https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com' +
           '%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy',
    hosts: ['gog.com'],
    shape: /^[A-Za-z0-9_\-.~]{10,2048}$/,  // the store helper's code_shape
    // GOG ends on a redirect that carries the code: it is taken from the address, before the page loads.
    codeIn: (url) => url.hostname === 'embed.gog.com' && url.pathname === '/on_login_success'
      ? url.searchParams.get('code') : null,
  },
  epic: {
    start: 'https://www.epicgames.com/id/login?redirectUrl=' + encodeURIComponent(EPIC_REDIRECT),
    hosts: ['epicgames.com', 'unrealengine.com', 'fortnite.com'],
    shape: /^[0-9a-f]{32}$/,
    // Epic ends on a page of JSON with the code in it: read once the page has loaded.
    isCodePage: (url) => url.hostname === 'www.epicgames.com' && url.pathname === '/id/api/redirect',
  },
};

function log(msg) {
  process.stderr.write(`store-signin: ${msg}\n`);
}

function hostAllowed(store, hostname) {
  return [...store.hosts, ...SIGN_IN_HOSTS].some((h) => hostname === h || hostname.endsWith('.' + h));
}

function parse(raw) {
  try {
    return new URL(raw);
  } catch {
    return null;
  }
}

const name = process.argv.slice(1).filter((a) => !a.startsWith('-')).pop();
const store = STORES[name];
if (!store) {
  log(`usage: electron <app> <${Object.keys(STORES).join('|')}>`);
  process.exit(2);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'rf-store-signin-'));
app.setPath('userData', scratch);
app.setPath('sessionData', scratch);
app.userAgentFallback = app.userAgentFallback
  .replace(/ Electron\/\S+/, '')
  .replace(new RegExp(` ${app.getName()}\\/\\S+`), '');

let done = false;

// Chromium's folder goes before the exit: app.exit() does not run Node's exit handlers.
function quit(status) {
  fs.rmSync(scratch, { recursive: true, force: true });
  app.exit(status);
}

function finish(code) {
  if (done) return;
  if (!store.shape.test(code)) {
    log(`the ${name} page gave something that is not a code (${code.length} characters); still waiting`);
    return;
  }
  done = true;
  process.stdout.write(JSON.stringify({ store: name, code }) + '\n');
  quit(0);
}

// Every top-frame navigation, the window's and a popup's: the code, else allowed or refused.
function guard(contents) {
  const check = (event, raw) => {
    const url = parse(raw);
    const code = url && store.codeIn ? store.codeIn(url) : null;
    if (code) {
      event.preventDefault();
      finish(code);
    } else if (!url || url.protocol !== 'https:' || !hostAllowed(store, url.hostname)) {
      event.preventDefault();
      log(`refused a navigation to ${url ? url.protocol + '//' + url.hostname : raw}`);
    }
  };
  contents.on('will-navigate', check);
  contents.on('will-redirect', check);
  contents.on('did-finish-load', async () => {
    const url = parse(contents.getURL());
    if (!url || !store.isCodePage || !store.isCodePage(url)) return;
    try {
      const body = JSON.parse(await contents.executeJavaScript('document.body.innerText'));
      if (body.authorizationCode) finish(String(body.authorizationCode));
      else log('Epic\'s code page has no authorizationCode (not signed in yet?)');
    } catch (err) {
      log(`could not read Epic's code page: ${err.message}`);
    }
  });
  // A page that does not load is tried again: there is no address bar to reload it from, and the
  // first load can race Wi-Fi coming back from sleep (ERR_TIMED_OUT on the Air X, 2026-10-28).
  contents.on('did-fail-load', (_e, errorCode, description, raw, isMainFrame) => {
    if (!isMainFrame || errorCode === -3) return;  // -3: aborted, ours
    log(`could not load ${raw}: ${description} (${errorCode}); trying again in ${RETRY_MS / 1000} s`);
    setTimeout(() => {
      if (!done && !contents.isDestroyed()) contents.loadURL(raw);
    }, RETRY_MS);
  });
  contents.setWindowOpenHandler(({ url: raw }) => {
    const url = parse(raw);
    if (url && url.protocol === 'https:' && hostAllowed(store, url.hostname)) {
      return { action: 'allow', overrideBrowserWindowOptions: { fullscreen: true, frame: false, autoHideMenuBar: true } };
    }
    log(`refused a window for ${url ? url.hostname : raw}`);
    return { action: 'deny' };
  });
  contents.on('did-create-window', (child) => guard(child.webContents));
}

app.on('web-contents-created', (_e, contents) => {
  contents.on('will-attach-webview', (event) => event.preventDefault());
});

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  const ses = session.fromPartition('signin');
  ses.setUserAgent(app.userAgentFallback);
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  ses.on('will-download', (event) => event.preventDefault());

  const win = new BrowserWindow({
    fullscreen: true,
    frame: false,
    autoHideMenuBar: true,
    backgroundColor: '#000000',
    title: name === 'gog' ? 'GOG sign-in' : 'Epic Games sign-in',
    webPreferences: { partition: 'signin', sandbox: true, contextIsolation: true, nodeIntegration: false,
                      spellcheck: false },
  });
  guard(win.webContents);
  win.loadURL(store.start);
  setTimeout(() => {
    log('15 minutes without a code; giving up');
    quit(1);
  }, TIMEOUT_MS).unref();
});

app.on('window-all-closed', () => {
  if (!done) log('closed without a code');
  quit(done ? 0 : 1);
});
