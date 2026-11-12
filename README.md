# FixMyScan for KOReader

Turns a scanned PDF or DjVu into a clean, searchable PDF from inside
[KOReader](https://github.com/koreader/koreader): pages cropped and
straightened, spreads split, searchable text added. The result is saved next to
the original as `<name> (fixed).pdf`; the original is never changed.

Needs a [FixMyScan](https://fixmyscan.com) account. It's free with limits;
Premium is for many books. Uploaded and converted files
are deleted from FixMyScan's servers within 24 hours.

GitHub topic for the KOReader plugin AppStore: `koreader-plugin`.

## Install

Copy the `fixmyscan.koplugin` folder into KOReader's `plugins` folder and
restart KOReader:

| Device | Folder |
| --- | --- |
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |
| Android | `koreader/plugins/` on internal storage |
| reMarkable | `plugins/` inside the KOReader folder |

## Use

1. Tools > FixMyScan > Connect. Scan the QR code with your phone, or go to
   app.fixmyscan.com/pair and enter the code shown. No typing on the e-reader.
2. With a PDF or DjVu open: Tools > FixMyScan > Fix with FixMyScan. In the
   file browser: long-press the file > Fix with FixMyScan.
3. Progress shows while it works. Stop cancels the book on the server; Keep
   reading hides the dialog and a message appears when it's ready.
4. When it's done, choose Open it.

Disconnect is under Tools > FixMyScan and shows the connected email.

## How it works

- `api.lua`: HTTP and JSON over KOReader's LuaSocket/LuaSec (`socket.http`,
  `ssl.https`, `socketutil` timeouts). No UI, so it runs in a plain Lua.
- Pairing: `POST /v1/pair/start` then `POST /v1/pair/poll` every `interval`
  seconds until `approved` (a 410 means the code expired). The API key is
  stored in `settings/fixmyscan.lua`.
- Fixing: `POST /v1/uploads`, `PUT` the file to the presigned URL (streamed
  from disk with `Content-Length`), `POST /v1/books` with an `Idempotency-Key`,
  then `GET /v1/books/{id}` every 5 seconds, honouring `429 Retry-After`. The
  download goes to a `.part` file and is renamed when complete. A book still
  converting when the connection drops picks up where it left off the next
  time you choose Fix with FixMyScan.
- API reference: <https://api.fixmyscan.com/openapi.json>.
- For testing, set `base_url` in `settings/fixmyscan.lua` to another server.

## Tests

`../tests/run_tests.sh` runs `api.lua` and the menu and dialog flows (with
KOReader's UI stubbed) against a fake API in `../tests/fake_api.py`. Use
`KOREADER_DIR=/path/to/koreader` to run them on KOReader's own LuaJIT and
libraries, or install `luajit` plus the `luasocket` and `dkjson` rocks.

## Licence

AGPL-3.0, the same as KOReader. See `LICENSE`.
