# webproxy

Run it on one computer (the host); open the printed link in any browser on any other device. The host fetches pages, so the other device never contacts the real sites.

## Host (Linux, macOS, Windows, Android)

```
curl -fsSL https://raw.githubusercontent.com/fordpepper/webproxy/main/webproxy.sh | bash
```
or download `webproxy.sh` and run `bash webproxy.sh` (add `-open` for no access control).

- **Linux / macOS:** needs `curl` and `tar`. Go and cloudflared are downloaded temporarily and deleted on exit.
- **Windows:** run in Git Bash (or WSL).
- **Android:** in Termux, first `pkg install golang cloudflared curl`.

## Viewer

Any device with a browser: open the link the host prints, or https://fordpepper.github.io/webproxy/ and enter the access key.
