# Book Fetcher

Book Fetcher brings DRM-free books to an e-reader. The macOS app imports direct
book links and files, converts them to AZW3 with Calibre, and serves a library
page over the local network. The iPhone companion can import books, build a
library on the phone, and share it with an e-reader through its browser.

## Install

Book Fetcher runs on macOS 14 or later. Download the `.dmg` from
https://github.com/lalalaoneplus-dev/book-fetcher/releases/latest, drag
**Book Fetcher.app** to Applications, and open it. The app installs its local
library helpers on launch. Calibre is required; download it from
https://calibre-ebook.com/download_osx and place it in Applications.

## Bring books into the Mac library

- Paste a direct, DRM-free book link or choose files and ZIP bundles already on
  the Mac. Each supported book in a bundle is processed separately.
- The Mac accepts the input formats provided by the installed Calibre input
  plugins, including EPUB, KEPUB, PDF, TXT, Markdown, HTML, RTF, DOCX, ODT,
  FB2, comic archives, MOBI, and AZW. Existing AZW3 files go straight into the
  library; other formats are converted to AZW3 with Calibre's generic e-ink
  profile.
- Books with recognizable titles and authors can receive a matching Open
  Library cover. **Repair Covers** restores missing Calibre thumbnails and
  embeds artwork in AZW3 files.

Original downloads are stored in `~/Downloads/Book Fetcher/Originals` and
converted files in `~/Downloads/Book Fetcher/Ready`.

## Build and run on macOS

Book Fetcher runs on macOS 14 or later and uses Calibre at
`/Applications/calibre.app`.

```sh
./script/build_and_run.sh
```

The packaging script builds `Book Fetcher.app` in `dist/` and opens it. Set
`SIGN_IDENTITY` to use a signing certificate; otherwise it uses ad-hoc signing.
Set `NOTARY_PROFILE` alongside `SIGN_IDENTITY` to submit the signed app for
notarization.

Run `./script/package.sh` to build the universal release app and DMG in `dist/`.
Run `./script/uninstall.sh` to remove the local helpers and agents while keeping books and the pairing token.

## Install the Mac app and local library helper

```sh
./script/build_and_run.sh --install
```

Installation places the app in `~/Applications` with a Desktop shortcut. It
copies an existing Calibre library into
`~/Library/Application Support/Book Fetcher/Calibre Library`, preferring
`~/Documents/Book LAN Library` and then discovering a library under Documents
or Application Support. The source library is preserved.

The local helper listens on the Mac's private Wi-Fi IPv4 address on port 8090.
It serves the library page at `http://<Mac-Wi-Fi-IP>:8090/` and uses a pairing
token stored with user-only permissions. Enter that address and token in the
iPhone companion to send books to the Mac or mirror its library. The Mac app
starts the helper when opened, and the services follow Wi-Fi address changes.

**Choose Books…** adds stored files and ZIP bundles to the managed library.
**Summarize a book in PDFPivot** prepares a DRM-free EPUB or PDF from the
library, stores the PDF in `~/Downloads/Book Fetcher/Summaries`, and starts
PDFPivot's whole-document Summary pipeline.

## Share books from iPhone

The companion runs on iOS 17 or later. Open
`iOS/BookFetcherIOS.xcodeproj` in Xcode; `iOS/project.yml` defines the project
for XcodeGen. On the iPhone, direct links and Files imports can be downloaded,
unpacked, converted, stored, and shared without a Mac. EPUB, HTML, TXT,
Markdown, RTF, DOCX, ODT, FB2, and CBZ convert to reflowable MOBI; existing
MOBI, AZW, AZW3, and PDF files are stored as received. ZIP, HTMLZ, TXTZ, and
FBZ bundles are checked and processed in batches, with a 500 MB and 1,000-entry
archive limit.

The iPhone can also mirror the Mac's AZW3 library. Its local library page opens
at the address shown in the app, using port 80 where available and port 8090
as a fallback. Connect an e-reader to the iPhone's hotspot, open its
browser, and visit that address to download a book. Keep Book Fetcher in the
foreground while the iPhone serves the page.
