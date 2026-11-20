#!/usr/bin/env bash
# webproxy.sh - one file. Run:  bash webproxy.sh          (add -open for no access control)
#
# Files: nothing is installed or left behind. Go, cloudflared and the build live in a temporary
# folder that is deleted when you stop the program. The only file that can ever appear is
# webproxy.key next to this script, and only if you type an access key when asked.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KEYFILE="$HERE/webproxy.key"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/webproxy.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
# Any config/cache that tools want to write goes into the temporary folder, never into your home folder.
export XDG_CONFIG_HOME="$TMP/cfg" XDG_CACHE_HOME="$TMP/cache" GOENV=off GOTOOLCHAIN=local GOCACHE="$TMP/gocache" GOPATH="$TMP/gopath" GOFLAGS=-modcacherw
trap 'exit 130' INT TERM
GOVER="1.22.5"

OS=$(uname -s | tr 'A-Z' 'a-z')
EXE=""
case "$OS" in
  linux|darwin) ;;
  mingw*|msys*|cygwin*) OS=windows; EXE=".exe";;   # Git Bash / MSYS2 / Cygwin on Windows
  *) echo "Unsupported OS: $OS (use Linux, macOS, Windows Git Bash/WSL, or Android Termux)"; exit 1;;
esac
# Android Termux: its libc differs, so use Termux's own packages instead of downloading binaries.
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then
  for t in golang cloudflared; do
    b=$t; [ $t = golang ] && b=go
    command -v $b >/dev/null || { echo "Run first:  pkg install $t"; exit 1; }
  done
fi
case "$(uname -m)" in
  x86_64|amd64) A=amd64; GA=amd64;;
  aarch64|arm64) A=arm64; GA=arm64;;
  armv7l|armv6l|armhf) A=arm; GA=armv6l;;
  i386|i686) A=386; GA=386;;
  *) echo "Unsupported CPU: $(uname -m)"; exit 1;;
esac
for t in curl tar; do command -v $t >/dev/null || { echo "Please install $t first."; exit 1; }; done

# ---- access key (and optional GitHub link settings), kept in webproxy.key only if you enter one ----
TOKEN="${WP_TOKEN:-}"; GH_OWNER=""; GH_REPO=""; GH_TOKEN=""
if [ -f "$KEYFILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in KEY) TOKEN="$v";; GH_OWNER) GH_OWNER="$v";; GH_REPO) GH_REPO="$v";; GH_TOKEN) GH_TOKEN="$v";; esac
  done < "$KEYFILE"
elif [ -z "$TOKEN" ] && ( : </dev/tty ) 2>/dev/null; then
  printf 'Access key (letters/numbers, 8+ characters). Enter = random one-time key, nothing saved: ' >/dev/tty
  read -rs TOKEN </dev/tty || TOKEN=""; echo >/dev/tty
  if [ -n "$TOKEN" ]; then
    if [[ ! "$TOKEN" =~ ^[A-Za-z0-9_-]{8,}$ ]]; then
      echo "That key is not allowed (use letters, numbers, - or _, at least 8). Using a random one-time key." >/dev/tty; TOKEN=""
    else
      printf 'Also keep ONE permanent address on GitHub Pages? [y/N] ' >/dev/tty; read -r ans </dev/tty || ans=n
      if [ "$ans" = y ] || [ "$ans" = Y ]; then
        printf 'GitHub username: ' >/dev/tty; read -r GO_ </dev/tty
        printf 'Repository name to create (for example: link): ' >/dev/tty; read -r GR_ </dev/tty
        printf 'Token (create at https://github.com/settings/tokens/new?scopes=public_repo , tick only public_repo; hidden): ' >/dev/tty
        read -rs GT_ </dev/tty; echo >/dev/tty
        if [[ "$GO_" =~ ^[A-Za-z0-9-]+$ && "$GR_" =~ ^[A-Za-z0-9._-]+$ && "$GT_" =~ ^[A-Za-z0-9_]+$ ]]; then
          GH_OWNER="$GO_"; GH_REPO="$GR_"; GH_TOKEN="$GT_"
        else echo "GitHub details did not look right, skipping GitHub." >/dev/tty; fi
      fi
      ( umask 077
        { echo "KEY=$TOKEN"
          [ -n "$GH_TOKEN" ] && [ -n "$GH_OWNER" ] && [ -n "$GH_REPO" ] && printf 'GH_OWNER=%s\nGH_REPO=%s\nGH_TOKEN=%s\n' "$GH_OWNER" "$GH_REPO" "$GH_TOKEN"
          true; } > "$KEYFILE" )
      echo "Saved to $KEYFILE" >/dev/tty
    fi
  fi
fi
export WP_TOKEN="$TOKEN" GH_OWNER GH_REPO GH_TOKEN

# ---- tools (temporary, removed on exit) ----
mkdir -p "$TMP/bin" "$TMP/src"
if ! command -v cloudflared >/dev/null 2>&1; then
  echo ">> Fetching cloudflared (temporary) ..."
  CFB="https://github.com/cloudflare/cloudflared/releases/latest/download"
  if [ "$OS" = darwin ]; then
    curl -fsSL "$CFB/cloudflared-darwin-${A}.tgz" | tar -C "$TMP/bin" -xz
  elif [ "$OS" = windows ]; then
    curl -fsSL -o "$TMP/bin/cloudflared.exe" "$CFB/cloudflared-windows-${A}.exe"
  else
    curl -fsSL -o "$TMP/bin/cloudflared" "$CFB/cloudflared-linux-${A}"
  fi
  chmod +x "$TMP/bin/cloudflared"*
fi
go_ok() {
  command -v go >/dev/null 2>&1 || return 1
  v=$(go env GOVERSION 2>/dev/null | sed 's/^go1\.\([0-9]*\).*/\1/')
  [ -n "$v" ] && [ "$v" -ge 18 ] 2>/dev/null
}
if ! go_ok; then
  echo ">> Fetching Go $GOVER (temporary) ..."
  if [ "$OS" = windows ]; then
    curl -fsSL -o "$TMP/go.zip" "https://go.dev/dl/go${GOVER}.windows-${GA}.zip"
    if command -v unzip >/dev/null; then unzip -q "$TMP/go.zip" -d "$TMP"; else tar -C "$TMP" -xf "$TMP/go.zip"; fi
  else
    curl -fsSL "https://go.dev/dl/go${GOVER}.${OS}-${GA}.tar.gz" | tar -C "$TMP" -xz
  fi
  export PATH="$TMP/go/bin:$PATH"
fi

cat > "$TMP/src/go.mod" <<'GOMODEOF'
module webproxy

go 1.18
GOMODEOF
cat > "$TMP/src/main.go" <<'GOEOF'
// webproxy: start it on the host, open the printed address in any browser on another computer.
// Pages are fetched by THIS computer and shown inside a locked frame, so the other computer never
// contacts the real sites directly.
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type sess struct {
	client *http.Client
	mu     sync.Mutex
	cur    string // origin of the site currently shown, e.g. https://www.youtube.com
	last   time.Time
}

func (s *sess) getCur() string  { s.mu.Lock(); defer s.mu.Unlock(); return s.cur }
func (s *sess) setCur(o string) { s.mu.Lock(); s.cur = o; s.mu.Unlock() }
func (s *sess) touch()          { s.mu.Lock(); s.last = time.Now(); s.mu.Unlock() }

var (
	token        string
	openMode     bool
	shared       *sess
	allowPrivate bool
	mu           sync.Mutex
	sessions     = map[string]*sess{}

	uiMu sync.Mutex
	ui   struct {
		tunnelURL, pagesURL, local, ghMsg string
		online, ghOK                      bool
	}
	tunnelWanted bool
	isTTY        bool
)

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func isPrivate(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified()
}

// Only used when WP_USE_ENV_PROXY=1 (for hosts that must reach the internet through a proxy).
func envProxy() func(*http.Request) (*url.URL, error) {
	if os.Getenv("WP_USE_ENV_PROXY") == "1" {
		return http.ProxyFromEnvironment
	}
	return nil
}

func newSess() *sess {
	jar, _ := cookiejar.New(nil)
	d := &net.Dialer{
		Timeout: 15 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			host, _, _ := net.SplitHostPort(address)
			if ip := net.ParseIP(host); ip != nil && !allowPrivate && isPrivate(ip) {
				return fmt.Errorf("blocked private address %s", host)
			}
			return nil
		},
	}
	tr := &http.Transport{
		Proxy:                 envProxy(),
		DialContext:           func(ctx context.Context, n, a string) (net.Conn, error) { return d.DialContext(ctx, n, a) },
		ForceAttemptHTTP2:     true,
		DisableCompression:    true,
		ResponseHeaderTimeout: 45 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       90 * time.Second,
	}
	return &sess{last: time.Now(), client: &http.Client{
		Jar:           jar,
		Transport:     tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

var sidKey []byte

func signID(id string) string {
	m := hmac.New(sha256.New, sidKey)
	m.Write([]byte(id))
	return hex.EncodeToString(m.Sum(nil))[:32]
}

func newCookieValue() string {
	id := randHex(12)
	return id + "." + signID(id)
}

// A browser stays signed in for good: the cookie is signed with your access key, so it is valid
// again after a restart. Per-browser state (open site, site cookies) is rebuilt on demand.
func session(r *http.Request) *sess {
	if openMode {
		return shared
	}
	c, err := r.Cookie("sid")
	if err != nil {
		return nil
	}
	i := strings.IndexByte(c.Value, '.')
	if i < 1 || !hmac.Equal([]byte(c.Value[i+1:]), []byte(signID(c.Value[:i]))) {
		return nil
	}
	id := c.Value[:i]
	mu.Lock()
	defer mu.Unlock()
	s := sessions[id]
	if s == nil {
		if len(sessions) >= 64 { // keep memory bounded: drop the least recently used browser state
			oldest, oid := time.Now(), ""
			for k, v := range sessions {
				v.mu.Lock()
				t := v.last
				v.mu.Unlock()
				if t.Before(oldest) {
					oldest, oid = t, k
				}
			}
			delete(sessions, oid)
		}
		s = newSess()
		sessions[id] = s
	}
	s.touch()
	return s
}

// ---------- the page you see ----------

// A proxied page may only talk to this server; the browser itself blocks everything else.
const faviconLink = `<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%20505.736%20505.736%22%3E%3Cstyle%3Epath%7Bfill:%23111%7D%40media(prefers-color-scheme:dark)%7Bpath%7Bfill:%23eee%7D%7D%3C/style%3E%3Cpath%20d=%22M396.007,191.19c-0.478,0-1.075,0-1.554,0c-6.693-54.147-52.833-96.103-108.773-96.103c-48.171,0-89.051,31.078-103.753,74.349c-16.734-8.128-35.381-12.67-55.224-12.67C56.658,156.765,0,213.542,0,283.707c0,67.416,52.594,122.64,118.934,126.703v0.239h277.91c60.244-0.358,108.893-49.366,108.893-109.729C505.617,240.317,456.609,191.19,396.007,191.19z%22/%3E%3C/svg%3E">`

const proxiedCSP = "default-src 'self' data: blob: 'unsafe-inline' 'unsafe-eval'; frame-src 'self' blob: data:; " +
	"worker-src 'self' blob:; connect-src 'self' blob: data:; form-action 'self'; base-uri 'self'"

const wrapperCSP = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data:; frame-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'"

const wrapperHTML = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><meta name="theme-color" content="#000"><meta name="color-scheme" content="dark"><title>browse</title>` + faviconLink + `
<style>
html,body{margin:0;height:100%;background:#000}
body{font:17px system-ui,-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;color:#444}
form{width:min(560px,86vw)}
input{width:100%;box-sizing:border-box;padding:15px 22px;font:inherit;color:#ddd;background:#000;border:1px solid #222;border-radius:999px;outline:none;caret-color:#888}
input::placeholder{color:#555}input:focus{border-color:#444}input.bad{border-color:#a33}
#l{display:none}
iframe{position:fixed;inset:0;width:100%;height:100%;border:0;background:#fff;display:none}
</style></head><body>
<form id="g"><input id="u" placeholder="enter a web address" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus></form>
<div id="l">loading</div>
<iframe id="f" sandbox="allow-scripts allow-same-origin allow-forms allow-downloads allow-modals allow-pointer-lock allow-presentation" allow="fullscreen; autoplay; encrypted-media; picture-in-picture; clipboard-write" allowfullscreen></iframe>
<script>
(function(){
var f=document.getElementById("f"),g=document.getElementById("g"),u=document.getElementById("u"),l=document.getElementById("l"),started=false,shown=false;
function nav(a){try{var x=new URL(a);return "/__wp/n/"+x.protocol.slice(0,-1)+"/"+x.host+x.pathname+x.search}catch(e){return null}}
function start(p){started=true;g.style.display="none";l.style.display="block";f.src=p;
 setTimeout(function(){reveal()},10000)}
function reveal(){if(started&&!shown){shown=true;l.style.display="none";f.style.display="block"}}
function norm(t){t=t.trim();
 if(/^https?:\/\/[^\s]+$/i.test(t))return t;
 if(/^[^\s\/?#]+\.[a-z]{2,}([\/?#][^\s]*)?$/i.test(t))return "https://"+t;
 return null}
function go(t){var a=norm(t);if(!a){u.classList.add("bad");return}
 var p=nav(a);if(p)start(p)}
u.oninput=function(){u.classList.remove("bad")};
g.onsubmit=function(e){e.preventDefault();go(u.value)};
f.onload=function(){if(!started)return;reveal();try{var d=f.contentDocument,lo=f.contentWindow.location,p=lo.pathname+lo.search;
 if(p.indexOf("/__wp/")!==0){history.replaceState(null,"",p)}
 document.title=(d&&d.title)||lo.hostname||"browse"}catch(e){}};
// A page that tries to send its frame to a real site is blocked by the browser (frame-src 'self').
// We catch that and send the frame through the proxy instead. Nothing connects directly.
document.addEventListener("securitypolicyviolation",function(e){
 var d=e.violatedDirective||"";
 if((d.indexOf("frame-src")===0||d.indexOf("child-src")===0)&&/^https?:/i.test(e.blockedURI)){
  var p=nav(e.blockedURI);if(p){started=true;f.src=p}}});
var S=__START__,BASE=__BASE__,KEY=__KEY__,bad=0,last="",T=null;
function real(){try{var lo=f.contentWindow.location;if(last&&lo.pathname.indexOf("/__wp/")!==0)return last+lo.pathname+lo.search}catch(e){}return last}
function lost(){if(!BASE)return;var r=real();
 // only leave if GitHub is reachable from here, so a brief loss of this device's own connection is not mistaken for a dead tunnel
 fetch(BASE+"url.json?"+Date.now(),{mode:"no-cors",cache:"no-store"}).then(function(){location.replace(BASE+"#"+KEY+(r?"|"+encodeURIComponent(r):""))},function(){})}
// one tiny request per minute, and only while this tab is visible (none at all in the background)
function poll(){fetch("/__wp/state",{cache:"no-store",credentials:"same-origin"}).then(function(r){if(!r.ok)throw 0;return r.json()}).then(function(j){bad=0;last=j.cur||""}).catch(function(){bad++;if(bad>=2)lost();else setTimeout(poll,5000)})}
function sched(){clearInterval(T);if(!document.hidden)T=setInterval(poll,60000)}
document.addEventListener("visibilitychange",function(){sched();if(!document.hidden)poll()});
sched();poll();
if(S)start(S);
})();
</script></body></html>`

func homeBase() string {
	if v := os.Getenv("WP_TEST_HOME"); v != "" {
		return v
	}
	uiMu.Lock()
	defer uiMu.Unlock()
	if ui.ghOK {
		return ui.pagesURL
	}
	return ""
}

func wrapper(w http.ResponseWriter, start string) {
	b, _ := json.Marshal(start)
	base, _ := json.Marshal(homeBase())
	key, _ := json.Marshal(map[bool]string{true: "", false: token}[openMode])
	csp := wrapperCSP
	if bu, err := url.Parse(homeBase()); err == nil && bu.Host != "" {
		// the page may check one more place, and only that one: your own GitHub link
		csp = strings.Replace(csp, "connect-src 'self'", "connect-src 'self' "+bu.Scheme+"://"+bu.Host, 1)
	}
	w.Header().Set("Content-Security-Policy", csp)
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	io.WriteString(w, strings.NewReplacer("__START__", string(b), "__BASE__", string(base), "__KEY__", string(key)).Replace(wrapperHTML))
}

// ---------- rewriting ----------

type rctx struct {
	base *url.URL // the real URL of the document or file being rewritten
	root bool     // true: same-site links stay root-relative (the site is shown at its own paths)
}

func sitePath(prefix string, u *url.URL) string {
	p := u.EscapedPath()
	if p == "" {
		p = "/"
	}
	s := prefix + u.Scheme + "/" + u.Host + p
	if u.RawQuery != "" {
		s += "?" + u.RawQuery
	}
	return s
}

func (c rctx) ref(ref string, nav bool) string {
	ref = strings.TrimSpace(html.UnescapeString(ref))
	l := strings.ToLower(ref)
	if ref == "" || strings.HasPrefix(ref, "#") || strings.HasPrefix(l, "data:") || strings.HasPrefix(l, "javascript:") ||
		strings.HasPrefix(l, "mailto:") || strings.HasPrefix(l, "blob:") || strings.HasPrefix(l, "tel:") || strings.HasPrefix(l, "about:") {
		return ref
	}
	u, err := c.base.Parse(ref)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return ref
	}
	var out string
	same := u.Scheme == c.base.Scheme && u.Host == c.base.Host
	switch {
	case same && c.root:
		out = u.EscapedPath()
		if out == "" {
			out = "/"
		}
		out = "/" + strings.TrimLeft(out, "/")
		if u.RawQuery != "" {
			out += "?" + u.RawQuery
		}
	case same:
		out = sitePath("/__wp/p/", u)
	case nav:
		out = sitePath("/__wp/n/", u)
	default:
		out = sitePath("/__wp/p/", u)
	}
	if u.Fragment != "" {
		out += "#" + u.Fragment
	}
	return out
}

var (
	reTag        = regexp.MustCompile(`<([a-zA-Z][a-zA-Z0-9]*)(\s[^<>]*)>`)
	reAttr       = regexp.MustCompile(`(?i)\b(href|src|action|poster|data-src|data-href|formaction|data)\s*=\s*("([^"]*)"|'([^']*)')`)
	reSrcset     = regexp.MustCompile(`(?i)\bsrcset\s*=\s*"([^"]*)"`)
	reStyleAttr  = regexp.MustCompile(`(?i)\bstyle\s*=\s*"([^"]*)"`)
	reStyleBlock = regexp.MustCompile(`(?is)(<style[^>]*>)(.*?)(</style>)`)
	reIntegrity  = regexp.MustCompile(`(?i)\sintegrity\s*=\s*("[^"]*"|'[^']*')`)
	reBase       = regexp.MustCompile(`(?i)<base\b[^>]*>`)
	reMetaCSP    = regexp.MustCompile(`(?i)<meta[^>]*http-equiv\s*=\s*["']?content-security-policy[^>]*>`)
	reMetaRef    = regexp.MustCompile(`(?i)(<meta[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["']\s*\d+\s*;\s*url\s*=\s*)([^"'>]+)`)
	reHead       = regexp.MustCompile(`(?i)<head[^>]*>`)
	reCSSURL     = regexp.MustCompile(`(?i)url\(\s*(["']?)([^)"']+)(["']?)\s*\)`)
	reImportMap  = regexp.MustCompile(`(?is)(<script[^>]*type\s*=\s*["']?importmap["']?[^>]*>)(.*?)(</script>)`)
	reModScript  = regexp.MustCompile(`(?is)(<script[^>]*type\s*=\s*["']?module["']?[^>]*>)(.*?)(</script>)`)
	reJSURL      = regexp.MustCompile(`(["'])(https?://[^"'\s\\]+)(["'])`)
	reJSImport   = regexp.MustCompile(`((?:\bfrom|\bimport)\s*\(?\s*)(["'])(https?://[^"'\s\\]+)(["'])`)
	reImport     = regexp.MustCompile(`(?i)@import\s+["']([^"']+)["']`)
)

func (c rctx) css(s string) string {
	s = reCSSURL.ReplaceAllStringFunc(s, func(m string) string {
		sub := reCSSURL.FindStringSubmatch(m)
		return "url(" + sub[1] + c.ref(sub[2], false) + sub[3] + ")"
	})
	return reImport.ReplaceAllStringFunc(s, func(m string) string {
		sub := reImport.FindStringSubmatch(m)
		return strings.Replace(m, sub[1], c.ref(sub[1], false), 1)
	})
}

func (c rctx) importMap(s string) string {
	return reImportMap.ReplaceAllStringFunc(s, func(m string) string {
		x := reImportMap.FindStringSubmatch(m)
		body := reJSURL.ReplaceAllStringFunc(x[2], func(u string) string {
			y := reJSURL.FindStringSubmatch(u)
			return y[1] + c.ref(strings.ReplaceAll(y[2], `\/`, "/"), false) + y[3]
		})
		return x[1] + body + x[3]
	})
}

// js only touches static import/export-from statements; everything dynamic goes through the page shim.
func (c rctx) js(s string) string {
	return reJSImport.ReplaceAllStringFunc(s, func(m string) string {
		x := reJSImport.FindStringSubmatch(m)
		return x[1] + x[2] + c.ref(x[3], false) + x[4]
	})
}

func (c rctx) html(s string) string {
	s = c.importMap(s)
	s = reModScript.ReplaceAllStringFunc(s, func(m string) string {
		x := reModScript.FindStringSubmatch(m)
		return x[1] + c.js(x[2]) + x[3]
	})
	s = reIntegrity.ReplaceAllString(s, "")
	s = reBase.ReplaceAllString(s, "")
	s = reMetaCSP.ReplaceAllString(s, "")
	s = reMetaRef.ReplaceAllStringFunc(s, func(m string) string {
		sub := reMetaRef.FindStringSubmatch(m)
		return sub[1] + c.ref(sub[2], true)
	})
	s = reTag.ReplaceAllStringFunc(s, func(m string) string {
		sub := reTag.FindStringSubmatch(m)
		tag := strings.ToLower(sub[1])
		attrs := sub[2]
		attrs = reAttr.ReplaceAllStringFunc(attrs, func(a string) string {
			x := reAttr.FindStringSubmatch(a)
			name := strings.ToLower(x[1])
			q, val := `"`, x[3]
			if strings.HasPrefix(x[2], "'") {
				q, val = "'", x[4]
			}
			nav := ((tag == "a" || tag == "area") && name == "href") || (tag == "form" && name == "action")
			return x[1] + "=" + q + c.ref(val, nav) + q
		})
		attrs = reSrcset.ReplaceAllStringFunc(attrs, func(a string) string {
			x := reSrcset.FindStringSubmatch(a)
			parts := strings.Split(x[1], ",")
			for i, p := range parts {
				f := strings.Fields(p)
				if len(f) > 0 {
					f[0] = c.ref(f[0], false)
					parts[i] = strings.Join(f, " ")
				}
			}
			return `srcset="` + strings.Join(parts, ", ") + `"`
		})
		attrs = reStyleAttr.ReplaceAllStringFunc(attrs, func(a string) string {
			x := reStyleAttr.FindStringSubmatch(a)
			return `style="` + c.css(x[1]) + `"`
		})
		return "<" + sub[1] + attrs + ">"
	})
	s = reStyleBlock.ReplaceAllStringFunc(s, func(m string) string {
		x := reStyleBlock.FindStringSubmatch(m)
		return x[1] + c.css(x[2]) + x[3]
	})
	return s
}

const injectJS = `<script>(function(){
var SC="__SC__",H="__H__",ROOT=__ROOT__,o=location.origin;
function def(t,n,v){try{Object.defineProperty(t,n,{value:v,configurable:true,writable:true})}catch(e){}}
["RTCPeerConnection","webkitRTCPeerConnection","mozRTCPeerConnection","RTCDataChannel"].forEach(function(n){def(window,n,undefined)});
try{Object.defineProperty(navigator,"serviceWorker",{value:undefined,configurable:true})}catch(e){}
function ext(a,nav){return(nav?"/__wp/n/":"/__wp/p/")+a.protocol.slice(0,-1)+"/"+a.host+a.pathname+a.search+a.hash}
function px(u,nav){try{var a=new URL(u,document.baseURI);
 if(a.protocol!=="http:"&&a.protocol!=="https:")return u;
 if(a.origin===o){if(/^\/__wp\//.test(a.pathname)||ROOT)return u;return"/__wp/p/"+SC+"/"+H+a.pathname+a.search+a.hash}
 if(ROOT&&a.host===H&&a.protocol===SC+":")return a.pathname+a.search+a.hash;
 return ext(a,nav)}catch(e){return u}}
var F=window.fetch,xo=XMLHttpRequest.prototype.open,xs=XMLHttpRequest.prototype.send;
window.fetch=function(i,n){try{if(typeof i==="string")i=px(i);else if(i instanceof URL)i=px(i.href);else if(i instanceof Request){var q=px(i.url);if(q!==i.url)i=new Request(q,i)}}catch(e){}
 return F.call(this,i,n).then(function(r){try{if(r.headers.get("x-wp-ck"))ckT=0}catch(e){}return r})};
XMLHttpRequest.prototype.open=function(m,u){arguments[1]=px(String(u));this.addEventListener("readystatechange",function(){if(this.readyState===2){try{if(this.getResponseHeader("x-wp-ck"))ckT=0}catch(e){}}});return xo.apply(this,arguments)};
if(window.navigation&&navigation.addEventListener){navigation.addEventListener("navigate",function(e){try{
 if(e.hashChange||!e.cancelable)return;var a=new URL(e.destination.url);
 if((a.protocol==="http:"||a.protocol==="https:")&&a.origin!==o){e.preventDefault();location.href=px(e.destination.url,true)}}catch(x){}})}
if(navigator.sendBeacon){var sb=navigator.sendBeacon;navigator.sendBeacon=function(u,d){return sb.call(navigator,px(String(u)),d)}}
if(window.EventSource){var ES=window.EventSource;window.EventSource=function(u,c){return new ES(px(String(u)),c)};window.EventSource.prototype=ES.prototype}
["Worker","SharedWorker"].forEach(function(n){var W=window[n];if(!W)return;window[n]=function(u,c){return new W(px(String(u)),c)};window[n].prototype=W.prototype});
window.open=function(u){if(u)location.href=px(String(u),true);return null};
function hook(C,p,nav){try{if(!C)return;var d=Object.getOwnPropertyDescriptor(C.prototype,p);if(!d||!d.set)return;
 Object.defineProperty(C.prototype,p,{configurable:true,enumerable:d.enumerable,get:d.get,set:function(v){d.set.call(this,typeof v==="string"?px(v,nav):v)}})}catch(e){}}
[["HTMLScriptElement","src"],["HTMLImageElement","src"],["HTMLIFrameElement","src"],["HTMLLinkElement","href"],["HTMLMediaElement","src"],["HTMLSourceElement","src"],["HTMLTrackElement","src"],["HTMLEmbedElement","src"],["HTMLInputElement","src"],["HTMLObjectElement","data"]].forEach(function(x){hook(window[x[0]],x[1],false)});
hook(window.HTMLAnchorElement,"href",true);hook(window.HTMLAreaElement,"href",true);hook(window.HTMLFormElement,"action",true);
var sa=Element.prototype.setAttribute;
Element.prototype.setAttribute=function(n,v){try{var l=String(n).toLowerCase();if(typeof v==="string"&&(l==="src"||l==="href"||l==="action"||l==="poster"||l==="data"||l==="formaction")){var tg=this.tagName?this.tagName.toLowerCase():"";v=px(v,(tg==="a"||tg==="area"||tg==="form")&&(l==="href"||l==="action"))}}catch(e){}return sa.call(this,n,v)};
var reA=/(\s(?:src|href|action|poster|data-src)\s*=\s*)(["'])((?:https?:)?\/\/[^"']*)\2/gi;
function fixHTML(s){return typeof s==="string"?s.replace(reA,function(m,a,q,u){return a+q+px(u)+q}):s}
["innerHTML","outerHTML"].forEach(function(n){var d=Object.getOwnPropertyDescriptor(Element.prototype,n);if(d&&d.set)Object.defineProperty(Element.prototype,n,{configurable:true,get:d.get,set:function(v){d.set.call(this,fixHTML(v))}})});
var iah=Element.prototype.insertAdjacentHTML;Element.prototype.insertAdjacentHTML=function(p,h){return iah.call(this,p,fixHTML(h))};
if(!ROOT){var hp=history.pushState,hr=history.replaceState;
 var fh=function(u){if(u==null)return u;try{var a=new URL(String(u),document.baseURI);if(a.origin===o&&!/^\/__wp\//.test(a.pathname))return"/__wp/p/"+SC+"/"+H+a.pathname+a.search+a.hash}catch(e){}return u};
 history.pushState=function(s,t,u){return hp.call(this,s,t,fh(u))};history.replaceState=function(s,t,u){return hr.call(this,s,t,fh(u))}}
document.addEventListener("click",function(e){var a=e.target&&e.target.closest&&e.target.closest("a[href]");if(a){a.target="_self";var h=a.getAttribute("href"),n=px(h,true);if(n!==h)a.setAttribute("href",n)}},true);
document.addEventListener("submit",function(e){var t=e.target;if(t&&t.getAttribute){var a=t.getAttribute("action");if(a){var n=px(a,true);if(n!==a)t.setAttribute("action",n)}t.target="_self"}},true);
function wrapStore(name){try{var s=window[name],pre=H+"\u0001";
 function ks(){var r=[];for(var i=0;i<s.length;i++){var k=s.key(i);if(k&&k.indexOf(pre)===0)r.push(k.slice(pre.length))}return r}
 var api={getItem:function(k){return s.getItem(pre+k)},setItem:function(k,v){s.setItem(pre+k,String(v))},removeItem:function(k){s.removeItem(pre+k)},clear:function(){ks().forEach(function(k){s.removeItem(pre+k)})},key:function(i){var a=ks();return i<a.length?a[i]:null}};
 var P=new Proxy(api,{get:function(t,p){if(p==="length")return ks().length;if(p in t)return t[p];if(typeof p==="symbol")return undefined;var v=s.getItem(pre+p);return v===null?undefined:v},
  set:function(t,p,v){s.setItem(pre+String(p),String(v));return true},has:function(t,p){return p in t||s.getItem(pre+String(p))!==null},
  deleteProperty:function(t,p){s.removeItem(pre+String(p));return true},ownKeys:function(){return ks()},
  getOwnPropertyDescriptor:function(t,p){var v=s.getItem(pre+String(p));return v===null?undefined:{value:v,writable:true,enumerable:true,configurable:true}}});
 Object.defineProperty(window,name,{configurable:true,get:function(){return P}})}catch(e){}}
wrapStore("localStorage");wrapStore("sessionStorage");
var ck=__CK__,ckT=Date.now();
function real(){var p=location.pathname,m=p.match(/^\/__wp\/p\/(https?)\/([^\/]+)(\/.*)?$/);if(m)return m[1]+"://"+m[2]+(m[3]||"/")+location.search;return SC+"://"+H+p+location.search}
function ckGet(){try{var x=new XMLHttpRequest();xo.call(x,"GET","/__wp/cookies?u="+encodeURIComponent(real()),false);xs.call(x);if(x.status===200){ck=x.responseText;ckT=Date.now()}}catch(e){}}
function ckSet(v){try{var n=v.split(";")[0],i=n.indexOf("="),name=(i<0?"":n.slice(0,i)).trim(),val=i<0?n:n.slice(i+1);
 var parts=ck?ck.split("; "):[];parts=parts.filter(function(c){return c.split("=")[0]!==name});
 if(!/expires=\w+,? 0?1 jan 1970|max-age=0|max-age=-/i.test(v))parts.push(name+"="+val);ck=parts.join("; ")}catch(e){}
 try{F.call(window,"/__wp/setcookie?u="+encodeURIComponent(real()),{method:"POST",body:v,keepalive:true,credentials:"same-origin"}).catch(function(){})}catch(e){}}
try{Object.defineProperty(Document.prototype,"cookie",{configurable:true,get:function(){if(Date.now()-ckT>3000)ckGet();return ck},set:function(v){ckSet(String(v))}})}catch(e){}
})();</script>`

func (c rctx) inject(s, ck string) string {
	cj, _ := json.Marshal(ck)
	root := "false"
	if c.root {
		root = "true"
	}
	js := strings.NewReplacer("__SC__", c.base.Scheme, "__H__", c.base.Host, "__ROOT__", root, "__CK__", string(cj)).Replace(injectJS)
	if loc := reHead.FindStringIndex(s); loc != nil {
		return s[:loc[1]] + js + s[loc[1]:]
	}
	return js + s
}

// ---------- request handling ----------

func splitSite(p string) (scheme, host, rest string, ok bool) {
	parts := strings.SplitN(p, "/", 3)
	if len(parts) < 2 || (parts[0] != "http" && parts[0] != "https") || parts[1] == "" {
		return "", "", "", false
	}
	rest = "/"
	if len(parts) == 3 {
		rest += parts[2]
	}
	return parts[0], parts[1], rest, true
}

// realFromRef turns a Referer that points at this server back into the real page URL.
func realFromRef(s *sess, ref string) (real string, explicit bool) {
	u, err := url.Parse(ref)
	if err != nil || ref == "" {
		return "", false
	}
	if strings.HasPrefix(u.Path, "/__wp/p/") || strings.HasPrefix(u.Path, "/__wp/n/") {
		if sc, h, rest, ok := splitSite(u.Path[len("/__wp/p/"):]); ok {
			q := ""
			if u.RawQuery != "" {
				q = "?" + u.RawQuery
			}
			return sc + "://" + h + rest + q, strings.HasPrefix(u.Path, "/__wp/p/")
		}
		return "", false
	}
	if strings.HasPrefix(u.Path, "/__wp/") {
		return "", false
	}
	if cur := s.getCur(); cur != "" {
		return cur + u.RequestURI(), false
	}
	return "", false
}

// afterLogin sends you to the start page, or back to the page you were on before the tunnel changed (?r=).
func afterLogin(w http.ResponseWriter, r *http.Request) {
	dest := "/"
	if rr := r.URL.Query().Get("r"); rr != "" {
		if u, err := url.Parse(rr); err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" {
			dest = sitePath("/__wp/n/", u)
		}
	}
	http.Redirect(w, r, dest, http.StatusSeeOther)
}

func handler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/__wp/ping" {
		atomic.StoreInt64(&lastActive, time.Now().Unix())
	}
	if r.URL.Path == "/__wp/ping" { // lets the link page check that this host is alive
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, "ok")
		return
	}
	k := r.URL.Query().Get("k")
	if openMode && r.URL.Query().Has("k") {
		shared.setCur("")
		afterLogin(w, r)
		return
	}
	if !openMode && token != "" && k != "" && subtle.ConstantTimeCompare([]byte(k), []byte(token)) == 1 {
		http.SetCookie(w, &http.Cookie{Name: "sid", Value: newCookieValue(), Path: "/", HttpOnly: true,
			Secure: r.Header.Get("X-Forwarded-Proto") == "https", SameSite: http.SameSiteLaxMode, MaxAge: 315360000})
		afterLogin(w, r)
		return
	}
	s := session(r)
	if s == nil {
		w.WriteHeader(http.StatusForbidden)
		io.WriteString(w, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#000"><body style="margin:0;height:100vh;background:#000;color:#666;font:15px system-ui,sans-serif;display:flex;align-items:center;justify-content:center;text-align:center">access denied<br>open the address shown by the host program</body>`)
		return
	}
	p := r.URL.Path
	switch {
	case p == "/__wp/state":
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"cur": s.getCur()})
	case p == "/__wp/cookies":
		u, err := url.Parse(r.URL.Query().Get("u"))
		if err != nil || u.Host == "" {
			http.Error(w, "bad url", 400)
			return
		}
		var parts []string
		for _, c := range s.client.Jar.Cookies(u) {
			parts = append(parts, c.Name+"="+c.Value)
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, strings.Join(parts, "; "))
	case p == "/__wp/setcookie" && r.Method == http.MethodPost:
		u, err := url.Parse(r.URL.Query().Get("u"))
		if err != nil || u.Host == "" {
			http.Error(w, "bad url", 400)
			return
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 8192))
		resp := &http.Response{Header: http.Header{"Set-Cookie": []string{string(b)}}}
		s.client.Jar.SetCookies(u, resp.Cookies())
		w.WriteHeader(http.StatusNoContent)
	case strings.HasPrefix(p, "/__wp/n/"):
		navigate(s, w, r)
	case strings.HasPrefix(p, "/__wp/p/"):
		sc, h, rest, ok := splitSite(strings.TrimPrefix(r.URL.EscapedPath(), "/__wp/p/"))
		if !ok {
			http.Error(w, "bad proxy path", 400)
			return
		}
		if r.Header.Get("Sec-Fetch-Dest") == "document" {
			wrapper(w, r.URL.RequestURI())
			return
		}
		serveProxy(s, w, r, &url.URL{Scheme: sc, Host: h}, rest, false)
	case strings.HasPrefix(p, "/__wp/"):
		http.NotFound(w, r)
	default:
		rootRequest(s, w, r)
	}
}

// /__wp/n/<scheme>/<host>/<path>: "show this site now". Makes it the current site, then
// moves to the same path on this server so the page sees its real paths (/watch?v=..., /search?q=...).
func navigate(s *sess, w http.ResponseWriter, r *http.Request) {
	sc, h, rest, ok := splitSite(strings.TrimPrefix(r.URL.EscapedPath(), "/__wp/n/"))
	if !ok {
		http.Error(w, "bad path", 400)
		return
	}
	s.setCur(sc + "://" + h)
	http.SetCookie(w, &http.Cookie{Name: "wpsite", Value: h, Path: "/"})
	loc := "/" + strings.TrimLeft(rest, "/")
	if r.URL.RawQuery != "" {
		loc += "?" + r.URL.RawQuery
	}
	code := http.StatusFound
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		code = http.StatusTemporaryRedirect
	}
	w.Header().Set("Location", loc)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
}

func rootRequest(s *sess, w http.ResponseWriter, r *http.Request) {
	// Requests from a page that was opened with an explicit /__wp/p/ address stay in that context.
	if real, explicit := realFromRef(s, r.Header.Get("Referer")); explicit && real != "" {
		if ru, err := url.Parse(real); err == nil {
			http.Redirect(w, r, "/__wp/p/"+ru.Scheme+"/"+ru.Host+r.URL.RequestURI(), http.StatusTemporaryRedirect)
			return
		}
	}
	cur := s.getCur()
	if r.Header.Get("Sec-Fetch-Dest") == "document" {
		if cur == "" {
			wrapper(w, "")
		} else {
			wrapper(w, r.URL.RequestURI())
		}
		return
	}
	if cur == "" {
		http.NotFound(w, r)
		return
	}
	site, err := url.Parse(cur)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	serveProxy(s, w, r, site, r.URL.EscapedPath(), true)
}

var skipReq = map[string]bool{"Host": true, "Cookie": true, "Referer": true, "Origin": true, "Accept-Encoding": true,
	"Connection": true, "X-Forwarded-For": true, "X-Forwarded-Proto": true, "Cf-Connecting-Ip": true, "Cf-Ray": true,
	"Cf-Visitor": true, "Cf-Ipcountry": true, "Cdn-Loop": true, "X-Forwarded-Host": true, "Content-Length": true}

// Response headers that must not reach the browser (they could make it contact the real site directly).
var skipResp = map[string]bool{"Content-Security-Policy": true, "Content-Security-Policy-Report-Only": true,
	"X-Frame-Options": true, "Set-Cookie": true, "Strict-Transport-Security": true,
	"Location": true, "Clear-Site-Data": true, "Link": true, "Report-To": true,
	"Nel": true, "Reporting-Endpoints": true, "Alt-Svc": true, "Cross-Origin-Opener-Policy": true,
	"Cross-Origin-Embedder-Policy": true, "Cross-Origin-Resource-Policy": true, "Referrer-Policy": true,
	"Permissions-Policy": true, "Accept-Ch": true, "Critical-Ch": true, "Vary": true}

func copyFlush(w http.ResponseWriter, rd io.Reader) {
	fl, _ := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, err := rd.Read(buf)
		if n > 0 {
			w.Write(buf[:n])
			if fl != nil {
				fl.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

func cookieString(s *sess, u *url.URL) string {
	var parts []string
	for _, c := range s.client.Jar.Cookies(u) {
		parts = append(parts, c.Name+"="+c.Value)
	}
	return strings.Join(parts, "; ")
}

func serveProxy(s *sess, w http.ResponseWriter, r *http.Request, site *url.URL, escPath string, root bool) {
	if escPath == "" {
		escPath = "/"
	}
	target := &url.URL{Scheme: site.Scheme, Host: site.Host, RawQuery: r.URL.RawQuery}
	target.Path, _ = url.PathUnescape(escPath)
	target.RawPath = escPath
	origin := target.Scheme + "://" + target.Host

	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), r.Body)
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	req.ContentLength = r.ContentLength
	for k, vv := range r.Header {
		if skipReq[http.CanonicalHeaderKey(k)] || strings.HasPrefix(k, "Sec-Fetch") {
			continue
		}
		req.Header[k] = vv
	}
	dest := r.Header.Get("Sec-Fetch-Dest")
	if dest == "" || dest == "document" || dest == "iframe" || dest == "frame" || dest == "style" || dest == "empty" || dest == "script" {
		req.Header.Set("Accept-Encoding", "gzip") // these may need rewriting, so ask for something we can read
	} else if ae := r.Header.Get("Accept-Encoding"); ae != "" {
		req.Header.Set("Accept-Encoding", ae) // scripts, images, video: pass the compressed bytes straight through
	}
	refURL, _ := realFromRef(s, r.Header.Get("Referer"))
	if refURL == "" {
		refURL = origin + "/"
	}
	req.Header.Set("Referer", refURL)
	if r.Header.Get("Origin") != "" {
		if ru, err := url.Parse(refURL); err == nil && ru.Host != "" {
			req.Header.Set("Origin", ru.Scheme+"://"+ru.Host)
		} else {
			req.Header.Set("Origin", origin)
		}
	}

	resp, err := s.client.Do(req)
	if err != nil {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusBadGateway)
		io.WriteString(w, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><body style="margin:0;height:100vh;background:#000;color:#666;font:15px system-ui,sans-serif;display:flex;align-items:center;justify-content:center;text-align:center;padding:0 20px">could not load this page<br>`+strings.ToLower(html.EscapeString(err.Error()))+`</body>`)
		return
	}
	defer resp.Body.Close()

	for k, vv := range resp.Header {
		if skipResp[http.CanonicalHeaderKey(k)] {
			continue
		}
		w.Header()[k] = vv
	}
	w.Header().Set("Content-Security-Policy", proxiedCSP)
	w.Header().Set("Referrer-Policy", "same-origin")
	if len(resp.Header.Values("Set-Cookie")) > 0 {
		w.Header().Set("X-Wp-Ck", "1") // tells the page's script that document.cookie changed
	}
	if root {
		w.Header().Set("Vary", "Cookie") // the same path on different sites must not share browser cache entries
	}
	c := rctx{base: target, root: root}
	if loc := resp.Header.Get("Location"); loc != "" {
		w.Header().Set("Location", c.ref(loc, root && (dest == "document" || dest == "iframe")))
	}
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	enc := strings.ToLower(resp.Header.Get("Content-Encoding"))
	canRead := enc == "" || enc == "gzip" || enc == "identity"
	switch {
	case canRead && strings.Contains(ct, "text/html"):
		out := c.html(readText(resp, enc))
		if dest != "empty" {
			out = c.inject(out, cookieString(s, target))
		}
		sendText(w, r, resp.StatusCode, out)
	case canRead && (strings.Contains(ct, "javascript") || strings.Contains(ct, "ecmascript")) && resp.ContentLength < 6<<20:
		sendText(w, r, resp.StatusCode, c.js(readText(resp, enc)))
	case canRead && strings.Contains(ct, "text/css"):
		sendText(w, r, resp.StatusCode, c.css(readText(resp, enc)))
	case resp.ContentLength >= 0 && !strings.Contains(ct, "event-stream"):
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	default:
		w.WriteHeader(resp.StatusCode)
		copyFlush(w, resp.Body)
	}
}

func readText(resp *http.Response, enc string) string {
	var rd io.Reader = resp.Body
	if enc == "gzip" {
		if gz, err := gzip.NewReader(resp.Body); err == nil {
			defer gz.Close()
			rd = gz
		}
	}
	b, _ := io.ReadAll(io.LimitReader(rd, 30<<20))
	return string(b)
}

func sendText(w http.ResponseWriter, r *http.Request, status int, body string) {
	w.Header().Del("Content-Length")
	w.Header().Del("Content-Encoding")
	w.Header().Add("Vary", "Accept-Encoding")
	if len(body) > 1024 && strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.WriteHeader(status)
		gz, _ := gzip.NewWriterLevel(w, gzip.BestSpeed)
		io.WriteString(gz, body)
		gz.Close()
		return
	}
	w.WriteHeader(status)
	io.WriteString(w, body)
}

// ---------- GitHub Pages link ----------

var ghBase = "https://api.github.com"

const pagesHTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>link</title>` + faviconLink + `
<meta name="theme-color" content="#000"><meta name="color-scheme" content="dark">
<style>
html,body{margin:0;height:100%;background:#000;color:#444}
body{font:15px system-ui,sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px}
input{width:min(320px,80vw);box-sizing:border-box;padding:13px 22px;font:inherit;border:1px solid #222;border-radius:999px;outline:none;text-align:center;color:#ddd;background:#000;caret-color:#888}
input::placeholder{color:#555}input:focus{border-color:#444}
</style>
<div id="s">connecting</div><input id="ki" type="password" placeholder="access key" style="display:none">
<script>
var O="__OWNER__",R="__REPO__",tries=0,h=location.hash.slice(1),i=h.indexOf("|"),key=i<0?h:h.slice(0,i),ret=i<0?"":decodeURIComponent(h.slice(i+1));
try{if(key)sessionStorage.setItem("wpk",key);else key=sessionStorage.getItem("wpk")||""}catch(e){}
if(location.hash)history.replaceState(null,"",location.pathname);
var s=document.getElementById("s"),ki=document.getElementById("ki");
async function file(){try{var r=await fetch("url.json?"+Date.now(),{cache:"no-store"});if(r.ok)return await r.json()}catch(e){}return null}
async function api(){try{var r=await fetch("https://api.github.com/repos/"+O+"/"+R+"/contents/url.json",{headers:{Accept:"application/vnd.github.raw+json"},cache:"no-store"});if(r.ok)return await r.json()}catch(e){}return null}
async function alive(u){try{var r=await fetch(u+"/__wp/ping",{cache:"no-store"});return (await r.text())==="ok"}catch(e){return false}}
async function tick(){
 var j=await file(),ok=j&&j.url&&await alive(j.url);
 if(!ok){j=await api();ok=j&&j.url&&await alive(j.url)}
 if(ok){
  if(!key&&!j.open){s.textContent="";ki.style.display="";ki.focus();return}
  location.replace(j.url+"/?k="+encodeURIComponent(key)+(ret?"&r="+encodeURIComponent(ret):""));return}
 s.textContent="waiting for the host";tries++;setTimeout(tick,Math.min(30000,3000+tries*2000))}
ki.onkeydown=function(e){if(e.key==="Enter"&&ki.value.trim()){key=ki.value.trim();try{sessionStorage.setItem("wpk",key)}catch(x){}ki.style.display="none";s.textContent="connecting";tries=0;tick()}};
tick();
</script>`

type ghub struct {
	owner, repo, tok string
	mu               sync.Mutex
	ready            bool
	note             string
}

func ghFromEnv() *ghub {
	o, r, t := os.Getenv("GH_OWNER"), os.Getenv("GH_REPO"), os.Getenv("GH_TOKEN")
	if o == "" || r == "" || t == "" {
		return nil
	}
	if v := os.Getenv("GH_API_BASE"); v != "" {
		ghBase = v
	}
	return &ghub{owner: o, repo: r, tok: t}
}

func (g *ghub) api(method, path string, body interface{}) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, ghBase+path, rd)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+g.tok)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "webproxy")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, b, nil
}

func short(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 160 {
		s = s[:160]
	}
	return s
}

func (g *ghub) put(path, content, msg string) error {
	p := "/repos/" + g.owner + "/" + g.repo + "/contents/" + path
	code, b, err := g.api("GET", p, nil)
	if err != nil {
		return err
	}
	sha := ""
	if code == 200 {
		var m struct {
			SHA     string `json:"sha"`
			Content string `json:"content"`
		}
		json.Unmarshal(b, &m)
		sha = m.SHA
		if old, e := base64.StdEncoding.DecodeString(strings.ReplaceAll(m.Content, "\n", "")); e == nil && string(old) == content {
			return nil
		}
	}
	payload := map[string]interface{}{"message": msg, "content": base64.StdEncoding.EncodeToString([]byte(content))}
	if sha != "" {
		payload["sha"] = sha
	}
	code, b, err = g.api("PUT", p, payload)
	if err != nil {
		return err
	}
	if code/100 != 2 {
		return fmt.Errorf("HTTP %d: %s", code, short(b))
	}
	return nil
}

func (g *ghub) pagesURL() string {
	o := strings.ToLower(g.owner)
	if strings.EqualFold(g.repo, g.owner+".github.io") {
		return "https://" + o + ".github.io/"
	}
	return "https://" + o + ".github.io/" + g.repo + "/"
}

func (g *ghub) setup() error {
	if g.ready {
		return nil
	}
	code, _, err := g.api("GET", "/repos/"+g.owner+"/"+g.repo, nil)
	if err != nil {
		return err
	}
	switch {
	case code == 404:
		c2, b, e := g.api("POST", "/user/repos", map[string]interface{}{"name": g.repo, "description": "link page", "auto_init": true, "private": false})
		if e != nil {
			return e
		}
		if c2/100 != 2 {
			return fmt.Errorf("could not create the repository (HTTP %d): %s", c2, short(b))
		}
		time.Sleep(2 * time.Second)
	case code == 401 || code == 403:
		return fmt.Errorf("GitHub rejected the token (HTTP %d)", code)
	}
	g.api("POST", "/repos/"+g.owner+"/"+g.repo+"/pages", map[string]interface{}{"source": map[string]string{"branch": "main", "path": "/"}})
	if c, _, _ := g.api("GET", "/repos/"+g.owner+"/"+g.repo+"/pages", nil); c == 404 {
		g.note = " (turn on Pages: repo Settings > Pages > Deploy from branch main)"
	} else {
		g.note = ""
	}
	index := strings.NewReplacer("__OWNER__", g.owner, "__REPO__", g.repo).Replace(pagesHTML)
	var perr error
	for i := 0; i < 4; i++ {
		if perr = g.put("index.html", index, "link page"); perr == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if perr != nil {
		return perr
	}
	g.ready = true
	return nil
}

func setGH(msg string, ok bool, pages string) {
	uiMu.Lock()
	ui.ghMsg = msg
	if ok {
		ui.ghOK = true
		ui.pagesURL = pages
	}
	uiMu.Unlock()
	render()
}

func (g *ghub) try(u string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := g.setup(); err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]interface{}{"url": u, "open": openMode})
	if err := g.put("url.json", string(body)+"\n", "update link"); err != nil {
		return err
	}
	setGH("link updated "+time.Now().Format("15:04:05")+g.note, true, g.pagesURL())
	return nil
}

func (g *ghub) publish(u string) {
	for delay := 3 * time.Second; ; {
		uiMu.Lock()
		cur := ui.tunnelURL
		uiMu.Unlock()
		if cur != u {
			return // a newer tunnel replaced this one
		}
		err := g.try(u)
		if err == nil {
			return
		}
		setGH("GitHub: "+err.Error()+" (retrying)", false, "")
		time.Sleep(delay)
		if delay < time.Minute {
			delay *= 2
		}
	}
}

// ---------- tunnel supervision ----------

var (
	cmdMu  sync.Mutex
	curCmd *exec.Cmd
)

var lastActive int64 // unix seconds of the last real request; health checks slow down when nobody is using it

var reTunnel = regexp.MustCompile(`https://[a-z0-9-]+\.trycloudflare\.com`)

func internetUp() bool {
	if os.Getenv("WP_TEST_FAST") != "" {
		return true
	}
	c := &http.Client{Timeout: 6 * time.Second}
	for _, u := range []string{"https://1.1.1.1/cdn-cgi/trace", "https://www.google.com/generate_204"} {
		if resp, err := c.Get(u); err == nil {
			resp.Body.Close()
			return true
		}
	}
	return false
}

func alivePing(c *http.Client, u string) bool {
	resp, err := c.Get(u + "/__wp/ping")
	if err != nil {
		return false
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8))
	resp.Body.Close()
	return string(b) == "ok"
}

// health is deliberately lazy: it only exists to catch a tunnel that is "up" but no longer reachable.
// A tunnel that exits is restarted immediately without any polling. While nobody has used the proxy
// recently it checks every 15 minutes (a few bytes), while in use every 2 minutes. A failure is
// re-checked a few times before anything is replaced.
func health(u string, cmd *exec.Cmd, done <-chan struct{}) {
	grace, idle, active, gap := 60*time.Second, 15*time.Minute, 2*time.Minute, 20*time.Second
	if os.Getenv("WP_TEST_FAST") != "" {
		grace, idle, active, gap = 2*time.Second, time.Second, time.Second, time.Second
	}
	wait := func(d time.Duration) bool {
		select {
		case <-time.After(d):
			return true
		case <-done:
			return false
		}
	}
	if !wait(grace) {
		return
	}
	c := &http.Client{Timeout: 10 * time.Second}
	for {
		every := idle
		if time.Since(time.Unix(atomic.LoadInt64(&lastActive), 0)) < 15*time.Minute {
			every = active
		}
		if !wait(every) {
			return
		}
		if alivePing(c, u) {
			continue
		}
		dead := true
		for i := 0; i < 3 && dead; i++ {
			if !wait(gap) {
				return
			}
			dead = !alivePing(c, u)
		}
		if dead && internetUp() { // the tunnel is dead, not just this computer's connection
			cmd.Process.Kill() // the supervisor starts a fresh tunnel and publishes the new address
			return
		}
	}
}

func supervise(port string, g *ghub) {
	backoff := 2 * time.Second
	for {
		cmd := exec.Command("cloudflared", "tunnel", "--url", "http://localhost:"+port, "--no-autoupdate")
		stderr, _ := cmd.StderrPipe()
		if err := cmd.Start(); err != nil {
			uiMu.Lock()
			ui.ghMsg = "cloudflared could not start: " + err.Error()
			uiMu.Unlock()
			render()
			time.Sleep(10 * time.Second)
			continue
		}
		cmdMu.Lock()
		curCmd = cmd
		cmdMu.Unlock()
		started := time.Now()
		done := make(chan struct{})
		go func() {
			cur := ""
			sc := bufio.NewScanner(stderr)
			for sc.Scan() {
				if u := reTunnel.FindString(sc.Text()); u != "" && u != cur && u != "https://api.trycloudflare.com" {
					cur = u
					uiMu.Lock()
					ui.tunnelURL, ui.online = u, true
					uiMu.Unlock()
					render()
					if g != nil {
						go g.publish(u)
					}
					go health(u, cmd, done)
				}
			}
		}()
		cmd.Wait()
		close(done)
		uiMu.Lock()
		ui.online = false
		uiMu.Unlock()
		render()
		if time.Since(started) > time.Minute {
			backoff = 2 * time.Second
		}
		time.Sleep(backoff)
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// ---------- screen ----------

func render() {
	uiMu.Lock()
	defer uiMu.Unlock()
	if isTTY {
		fmt.Print("\033[2J\033[H")
	}
	fmt.Print("webproxy is running (Ctrl+C stops it)\n\n")
	if openMode {
		fmt.Print("WARNING: -open is on. Anyone who has the address can use this computer as a proxy.\n\n")
	}
	link := ""
	switch {
	case ui.ghOK && ui.pagesURL != "":
		link = ui.pagesURL
		if !openMode {
			link += "#" + token
		}
	case ui.tunnelURL != "" && ui.online:
		link = ui.tunnelURL
		if !openMode {
			link += "/?k=" + token
		}
	}
	switch {
	case link != "":
		fmt.Printf("  Open this on the other computer:\n\n      %s\n\n", link)
	case tunnelWanted:
		fmt.Print("  Starting the tunnel ...\n\n")
	default:
		fmt.Printf("  Local link:\n\n      %s\n\n", ui.local)
	}
	if tunnelWanted {
		if ui.online {
			fmt.Println("  tunnel: online")
		} else {
			fmt.Println("  tunnel: reconnecting ...")
		}
	}
	if ui.ghMsg != "" {
		fmt.Println("  github: " + ui.ghMsg)
	}
}

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "listen address (default: any free port, local only)")
	flag.StringVar(&token, "token", os.Getenv("WP_TOKEN"), "secret for the access link (default: random, not saved)")
	flag.BoolVar(&openMode, "open", false, "NO access control: anyone who finds the address can use this computer as a proxy")
	tunnel := flag.Bool("tunnel", false, "start a free Cloudflare quick tunnel (restarts itself if it dies)")
	flag.BoolVar(&allowPrivate, "allow-private", false, "allow access to the host's own network (off by default)")
	flag.Parse()
	if fi, err := os.Stdout.Stat(); err == nil {
		isTTY = fi.Mode()&os.ModeCharDevice != 0
	}
	if openMode {
		shared = newSess()
	} else if token == "" {
		token = randHex(12)
	}
	k := sha256.Sum256([]byte("wp-sid:" + token))
	sidKey = k[:]
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	ui.local = "http://localhost:" + port
	if !openMode {
		ui.local += "/?k=" + token
	}
	go func() { log.Fatal(http.Serve(ln, http.HandlerFunc(handler))) }()

	g := ghFromEnv()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		cmdMu.Lock()
		if curCmd != nil && curCmd.Process != nil {
			curCmd.Process.Kill()
		}
		cmdMu.Unlock()
		if g != nil && g.ready {
			body, _ := json.Marshal(map[string]interface{}{"url": "", "open": openMode})
			g.put("url.json", string(body)+"\n", "host stopped")
		}
		os.Exit(0)
	}()

	if *tunnel {
		tunnelWanted = true
		if _, err := exec.LookPath("cloudflared"); err != nil {
			log.Fatal("cloudflared not found; run webproxy.sh, which installs it")
		}
		render()
		supervise(port, g)
		return
	}
	render()
	select {}
}
GOEOF
echo ">> Building ..."
(cd "$TMP/src" && go build -trimpath -ldflags "-s -w" -o "$TMP/bin/webproxy$EXE" .)

export PATH="$TMP/bin:$PATH"
"$TMP/bin/webproxy$EXE" -tunnel "$@"
