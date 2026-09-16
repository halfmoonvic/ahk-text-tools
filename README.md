# text-tools

Select text anywhere in Windows, press a hotkey, and get a translation — or a
Japanese reading — in a popup that follows your system light/dark theme.

| Hotkey | Action |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>Win</kbd>+<kbd>A</kbd> | Translate the selection (one panel per configured engine) |
| <kbd>Ctrl</kbd>+<kbd>Win</kbd>+<kbd>S</kbd> | Annotate Japanese text with kana / furigana |

The translate popup also has a text box, so you can keep typing new phrases
without re-selecting anything. Results stream in as they arrive, each engine in
its own panel with a Copy button.

## Requirements

| Component | Needed for | Notes |
| --- | --- | --- |
| [AutoHotkey v2](https://www.autohotkey.com/) | everything | v2 only — v1 will not run this script |
| PowerShell | everything | Windows PowerShell 5.1 and PowerShell 7+ both work |
| [Node.js](https://nodejs.org/) | kana only | translation works fine without it |
| Git Bash with `gawk` + `cygpath` | the `google` engine only | ships with [Git for Windows](https://git-scm.com/download/win) |

## Install

```powershell
git clone <this-repo> text-tools
cd text-tools
.\deploy.ps1
```

That copies the program files to `~\.local\bin`, downloads the Japanese
dictionary data, and writes starter configuration to `~\.config`. Then:

1. If you want AI translation, put your API keys in `~\.config\translate\auth.json`.
   Skip this if you only use the free `google` engine.
2. Run `~\.local\bin\auto_hotkey\text.ahk`.
3. Select some text and press <kbd>Ctrl</kbd>+<kbd>Win</kbd>+<kbd>A</kbd>.

To start it automatically, put a shortcut to `text.ahk` in your Startup folder
(<kbd>Win</kbd>+<kbd>R</kbd> → `shell:startup`).

### deploy.ps1

Re-run it any time; it only writes what actually changed.

| Option | Effect |
| --- | --- |
| `-TargetDir <path>` | Where program files go (default `~\.local\bin`) |
| `-ConfigDir <path>` | Where configuration goes (default `~\.config`) |
| `-Update` | `git pull --ff-only` first, then deploy |
| `-SkipVendor` | Don't download the Japanese dictionary data |
| `-Force` | Overwrite customised config (backs it up first) and re-download vendor files |
| `-WhatIf` | Show what would happen, write nothing |

How it decides what to do:

- **Program files** are compared by SHA-256 and copied only when they differ.
- **Vendor files** are skipped entirely when all 14 are present; otherwise only
  the missing ones are fetched. Nothing is downloaded on a normal re-run.
- **Configuration** is never silently overwritten. A file you have customised is
  kept and reported; `auth.json` is written once and then never touched again,
  because it holds your API keys.

Updating later:

```powershell
.\deploy.ps1 -Update
```

## Configuration

### `~\.config\ahk\settings.json`

Read by the AutoHotkey front-end.

```jsonc
{
  "translate": ["google", "openai/gpt-5.6-sol"],  // one panel per entry
  "ui": {
    "theme": "auto",            // auto | light | dark
    "alwaysOnTop": false,
    "fontSize": 16,             // 1-72
    "fontName": "Microsoft YaHei UI",
    "width": 960,               // 200-10000
    "minHeight": 800,           // 150-10000
    "maxHeight": 1000,          // 150-10000
    "lineHeight": 1,            // 0.8-4, multiple of the natural line height
    "padding": 14               // 0-48, inner padding of the text boxes
  },
  "japanese": { "kana": { "to": "hiragana", "mode": "furigana" } }
}
```

Each `translate` entry is either `google` (free, no key) or `provider/model`,
where `provider` matches a key in `models.json`.

`japanese.kana.to` picks the reading script — `hiragana`, `katakana`, or
`romaji`. `mode` is `ruby` for HTML `<ruby>` markup, or anything else
(conventionally `furigana`) for the plain `日本語（にほんご）` form.

### `~\.config\translate\`

| File | Purpose |
| --- | --- |
| `auth.json` | API keys, one per provider. **Never commit this.** |
| `models.json` | Providers, their base URLs, API flavour, and models |
| `config.json` | Default model, proxy, language-detection threshold, system prompt |

`api` in `models.json` must be one of `openai-completions`,
`openai-responses`, or `anthropic-messages`.

Set `TRANSLATE_CONFIG_DIR` to point the translator at a different directory —
useful for testing without disturbing your real keys.

## Command line

The translator and kana converter work on their own, which is the quickest way
to diagnose a problem without involving AutoHotkey:

```powershell
.\translate.ps1 -Text "Hello world"
.\translate.ps1 -Text "你好" -Mode google
.\translate.ps1 -Text "Hello" -Model openai/gpt-5.6-sol
"piped input works too" | .\translate.ps1
.\kana.ps1 -Text "日本語"
```

## Layout

`text.ahk` finds the other scripts by stripping `\auto_hotkey\<file>` from its
own path, so **this two-level structure is required**:

```
text-tools/
├── translate.ps1           <- must sit one level above auto_hotkey/
├── kana.ps1
├── auto_hotkey/
│   ├── text.ahk            <- entry point
│   ├── json.ahk, proc.ahk  <- #Include'd by text.ahk
│   └── run-task.ps1        <- wraps each child process
├── translate/              <- translation engine
│   ├── Translate.Core.psm1
│   ├── lib/, adapters/
│   └── google              <- third-party, see THIRD_PARTY.md
└── kana/
    ├── kana.mjs
    └── vendor/             <- fetched by deploy.ps1, not in git
```

Moving `text.ahk` out of `auto_hotkey/` breaks it.

## License

See `LICENSE`. Third-party components are listed in `THIRD_PARTY.md`.
