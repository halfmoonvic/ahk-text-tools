import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));

class LocalXMLHttpRequest {
  open(method, url) {
    this.url = url;
  }

  send() {
    fs.readFile(this.url, (error, data) => {
      if (error) {
        this.status = 404;
        this.statusText = error.message;
        this.onerror?.(error);
        return;
      }

      this.status = 200;
      this.response = data.buffer.slice(
        data.byteOffset,
        data.byteOffset + data.byteLength,
      );
      this.onload?.();
    });
  }
}

globalThis.XMLHttpRequest = LocalXMLHttpRequest;

const KuroshiroModule = require("./vendor/kuroshiro.min.js");
const kuromoji = require("./vendor/kuromoji.js");
const Kuroshiro = KuroshiroModule.default ?? KuroshiroModule;
const kanaToHiragana =
  Kuroshiro.Util.kanaToHiragana ?? Kuroshiro.Util.kanaToHiragna;

function parseArgs(argv) {
  const args = {
    input: "",
    output: "",
    to: "hiragana",
    mode: "furigana",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === "--input") {
      args.input = next ?? "";
      index += 1;
    } else if (arg === "--output") {
      args.output = next ?? "";
      index += 1;
    } else if (arg === "--to") {
      args.to = next ?? args.to;
      index += 1;
    } else if (arg === "--mode") {
      args.mode = next ?? args.mode;
      index += 1;
    }
  }

  return args;
}

function hasKanji(value) {
  return /\p{Script=Han}/u.test(value);
}

function convertReading(reading, to) {
  if (!reading || reading === "*") {
    return "";
  }

  if (to === "katakana") {
    return Kuroshiro.Util.kanaToKatakana(reading);
  }

  if (to === "romaji") {
    return Kuroshiro.Util.kanaToRomaji(reading);
  }

  return kanaToHiragana(reading);
}

function tokenStart(token, text, cursor) {
  const position = token.word_position;
  if (Number.isInteger(position) && position > 0) {
    return position - 1;
  }

  const found = text.indexOf(token.surface_form, cursor);
  return found >= 0 ? found : cursor;
}

function buildTokenizer() {
  const dicPath = path.join(scriptDir, "vendor", "dict") + path.sep;

  return new Promise((resolve, reject) => {
    kuromoji.builder({ dicPath }).build((error, tokenizer) => {
      if (error) {
        reject(error);
        return;
      }

      resolve(tokenizer);
    });
  });
}

async function annotate(text, options) {
  if (!text.trim()) {
    return "";
  }

  const tokenizer = await buildTokenizer();
  const tokens = tokenizer.tokenize(text);

  let output = "";
  let cursor = 0;

  for (const token of tokens) {
    const surface = token.surface_form ?? "";
    const start = tokenStart(token, text, cursor);

    if (start > cursor) {
      output += text.slice(cursor, start);
    }

    const reading = convertReading(token.reading, options.to);
    if (hasKanji(surface) && reading && reading !== surface) {
      if (options.mode === "ruby") {
        output += `<ruby>${surface}<rp>（</rp><rt>${reading}</rt><rp>）</rp></ruby>`;
      } else {
        output += `${surface}（${reading}）`;
      }
    } else {
      output += surface;
    }

    cursor = start + surface.length;
  }

  if (cursor < text.length) {
    output += text.slice(cursor);
  }

  return output;
}

const args = parseArgs(process.argv.slice(2));
if (!args.input) {
  throw new Error("Missing --input.");
}

const text = await fsp.readFile(args.input, "utf8");
const result = await annotate(text, args);

if (args.output) {
  await fsp.writeFile(args.output, result, "utf8");
} else {
  process.stdout.write(result);
}
