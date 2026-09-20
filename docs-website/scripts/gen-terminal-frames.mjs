#!/usr/bin/env node
// Captures real Guaranate terminal frames as colored HTML.
//
// The live frame is the part of Guaranate that a screenshot-free doc cannot
// honestly describe: a gradient progress bar, dimmed dot leaders, and
// color-coded assertion state. Hand-written mock-ups drift the moment the
// renderer changes, so these snapshots come from the real binary, driven under
// a pty by script(1) with a terminal that advertises truecolor.
//
// Each capture becomes the inner HTML of a `<pre>` — real text, one span per
// styled run — which `TerminalFrame.astro` drops into the page. The fragments
// are committed because the docs site builds on Linux, where the macOS-only
// binary cannot run. They are not checkable in CI the way the CLI reference
// is: every frame carries a wall clock, so two captures never match byte for
// byte. Re-run this script when the renderer changes.
//
// Usage:
//   node scripts/gen-terminal-frames.mjs     # capture and write the fragments
//
// Set GUARANATE_BIN to use an already-built binary.

import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(docsDir, '..');
const outputDir = join(docsDir, 'src/components/frames');

// --- The binary --------------------------------------------------------------

function resolveBinary() {
  if (process.env.GUARANATE_BIN) return process.env.GUARANATE_BIN;
  const built = execFileSync('swift', ['build', '-c', 'release', '--show-bin-path'], {
    cwd: repoRoot,
    encoding: 'utf8',
  }).trim();
  const binary = join(built, 'guaranate');
  if (!existsSync(binary)) {
    throw new Error(`No guaranate binary at ${binary}. Run \`swift build -c release\` first.`);
  }
  return binary;
}

// --- Capture -----------------------------------------------------------------

/**
 * Runs the binary under a pty and returns everything it wrote.
 *
 * script(1) is the pty: Guaranate renders the live frame only when stdout is a
 * terminal, and sizes it with TIOCGWINSZ. The environment is set rather than
 * inherited so a capture does not depend on the operator's own terminal —
 * NO_COLOR in particular would silently produce a monochrome snapshot.
 */
function capture(args, { runFor, interrupt = true }) {
  const child = spawn('script', ['-q', '/dev/null', ...args], {
    cwd: repoRoot,
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      TERM: 'xterm-256color',
      COLORTERM: 'truecolor',
      LANG: 'en_US.UTF-8',
      COLUMNS: '80',
      LINES: '24',
    },
    stdio: ['ignore', 'pipe', 'inherit'],
  });

  let output = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    output += chunk;
  });

  return new Promise((resolveCapture, rejectCapture) => {
    const timer = setTimeout(() => {
      if (interrupt) child.kill('SIGINT');
    }, runFor);
    child.on('error', rejectCapture);
    child.on('close', () => {
      clearTimeout(timer);
      resolveCapture(output);
    });
  });
}

/**
 * Splits a capture into the frames the renderer drew.
 *
 * Each redraw is preceded by "move up N lines, clear below", so that sequence
 * is the frame boundary. The leading fragment is whatever script(1) echoed
 * before the first frame and is dropped.
 */
function frames(output) {
  return output
    .split(/\u001b\[\d+A\u001b\[0J/)
    .slice(1)
    .map((frame) => frame.replace(/\u001b\[\?25[lh]/g, '').replace(/\r\n/g, '\n'))
    .map((frame) => frame.replace(/^\n+/, '').replace(/\n+$/, ''))
    .filter((frame) => frame.length > 0);
}

// --- ANSI → SVG ---------------------------------------------------------------

const ANSI_COLORS = {
  30: '#3b3b3b',
  31: '#d31a0e',
  32: '#7bbf3a',
  33: '#e0a33e',
  34: '#4a8fd4',
  35: '#b26ad4',
  36: '#3fb9b0',
  37: '#e8e2df',
  90: '#8a817c',
  91: '#ef5a4e',
  92: '#9fd45f',
  93: '#f0c368',
  94: '#7ab0e4',
  95: '#c993e4',
  96: '#6fd2ca',
  97: '#ffffff',
};

/** xterm-256 palette: 16 system colors, a 6×6×6 cube, then a gray ramp. */
function xterm256(index) {
  if (index < 8) return ANSI_COLORS[30 + index];
  if (index < 16) return ANSI_COLORS[90 + (index - 8)];
  if (index < 232) {
    const n = index - 16;
    const level = (v) => (v === 0 ? 0 : 55 + v * 40);
    const [r, g, b] = [Math.floor(n / 36) % 6, Math.floor(n / 6) % 6, n % 6];
    return rgb(level(r), level(g), level(b));
  }
  const v = 8 + (index - 232) * 10;
  return rgb(v, v, v);
}

const rgb = (r, g, b) => `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`;

const DEFAULT_STYLE = { color: null, bold: false, dim: false };

/** Applies one SGR sequence's parameters to the running style. */
function applySGR(style, params) {
  for (let i = 0; i < params.length; i += 1) {
    const code = params[i];
    if (code === 0) Object.assign(style, DEFAULT_STYLE);
    else if (code === 1) style.bold = true;
    else if (code === 2) style.dim = true;
    else if (code === 22) style.bold = style.dim = false;
    else if (code === 39) style.color = null;
    else if (ANSI_COLORS[code]) style.color = ANSI_COLORS[code];
    else if (code === 38 && params[i + 1] === 5) {
      style.color = xterm256(params[i + 2]);
      i += 2;
    } else if (code === 38 && params[i + 1] === 2) {
      style.color = rgb(params[i + 2], params[i + 3], params[i + 4]);
      i += 4;
    }
  }
  return style;
}

/**
 * One line of a frame as styled runs.
 *
 * The text is kept verbatim, spaces included: it is laid out by a `<pre>` on
 * the page, so the terminal's own padding is what aligns the columns.
 */
function runs(line) {
  const style = { ...DEFAULT_STYLE };
  const result = [];
  const pattern = /\u001b\[([0-9;]*)m/g;
  let cursor = 0;
  let match;
  const push = (text) => {
    if (text) result.push({ text, ...style });
  };
  while ((match = pattern.exec(line)) !== null) {
    push(line.slice(cursor, match.index));
    applySGR(style, match[1].split(';').map((p) => (p === '' ? 0 : Number(p))));
    cursor = pattern.lastIndex;
  }
  push(line.slice(cursor));
  return result;
}

const escapeHTML = (text) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/**
 * Renders a frame as the inner HTML of a `<pre>`: one span per styled run.
 *
 * Text rather than an image, so the frame is selectable, searchable, scales
 * with the reader's font size, and costs no extra request. `TerminalFrame`
 * owns the `<pre>` itself; everything here carries its colors inline, exactly
 * as the terminal emitted them.
 */
function html(frame) {
  return `${frame
    .split('\n')
    .map((line) =>
      runs(line)
        .map(({ text, color, bold, dim }) => {
          const css = [
            color ? `color:${color}` : null,
            bold ? 'font-weight:700' : null,
            dim ? 'opacity:.55' : null,
          ].filter(Boolean);
          const escaped = escapeHTML(text);
          return css.length ? `<span style="${css.join(';')}">${escaped}</span>` : escaped;
        })
        .join(''),
    )
    .join('\n')}\n`;
}

// --- Main ---------------------------------------------------------------------

const binary = resolveBinary();
mkdirSync(outputDir, { recursive: true });

function write(name, frame) {
  const path = join(outputDir, name);
  writeFileSync(path, html(frame));
  process.stdout.write(`Wrote ${relative(repoRoot, path)}\n`);
}

// A timed session: captured 12s into a 20s run, so the bar is partly filled,
// and again at the end for the completion card. The landing page reuses the
// running frame, so there is no separate capture for it.
const timed = frames(
  await capture([binary, '20', '--reason', 'release build'], { runFor: 20_000, interrupt: false }),
);
write('timed-session.html', timed[12]);
write('completion-card.html', timed.at(-1));

// A watch session needs something to watch: a sleep of our own, which
// outlives the capture and is cleaned up afterwards.
const watched = spawn('sleep', ['120'], { stdio: 'ignore' });
try {
  const watch = frames(await capture([binary, '--watch', String(watched.pid)], { runFor: 4_000 }));
  write('watch-session.html', watch.at(-2));
} finally {
  spawnSync('kill', [String(watched.pid)]);
}
