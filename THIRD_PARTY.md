# Third-party components

## Bundled in this repository

### `translate/google` — Translate Shell

- **Version:** 0.9.7.1 (released 2023-02-08)
- **Upstream:** <https://github.com/soimort/translate-shell>
- **License:** The Unlicense (public domain)

A self-contained `gawk` program that drives Google Translate from the command
line. It is invoked through `translate/lib/google-launch.sh` and provides the
free `google` engine, which needs no API key.

It requires Git Bash with `gawk` and `cygpath` on the host. The file must keep
LF line endings — `.gitattributes` enforces this, since Git Bash cannot execute
a script with CRLF endings.

## Downloaded by `deploy.ps1`

These land in `kana/vendor/` and are excluded from version control by
`.gitignore`. Both are used as-is from their npm packages; nothing is rebuilt.

### kuroshiro

- **Package:** [`kuroshiro`](https://www.npmjs.com/package/kuroshiro) → `dist/kuroshiro.min.js`
- **Upstream:** <https://github.com/hexenq/kuroshiro>
- **License:** MIT

Converts Japanese text to hiragana, katakana, or romaji, and produces furigana.

### kuromoji

- **Package:** [`kuromoji`](https://www.npmjs.com/package/kuromoji) → `build/kuromoji.js` and `dict/*.dat.gz`
- **Upstream:** <https://github.com/takuyaa/kuromoji.js>
- **License:** Apache License 2.0

A Japanese morphological analyser. The twelve `dict/*.dat.gz` files are a
compiled form of **IPADIC**, redistributed under its own terms:

> Copyright © 2000–2003 Nara Institute of Science and Technology.
> All Rights Reserved.

IPADIC is distributed under a BSD-style license that permits redistribution with
or without modification, provided the copyright notice is retained. See the
[IPADIC license](https://github.com/taku910/mecab/blob/master/mecab-ipadic/COPYING)
for the full text.
