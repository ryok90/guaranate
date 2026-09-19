#!/usr/bin/env node
// Captures real Guaranate terminal frames and renders them as SVG.
//
// The live frame is the part of Guaranate that a screenshot-free doc cannot
// honestly describe: a gradient progress bar, dimmed dot leaders, and
// color-coded assertion state. Hand-written mock-ups drift the moment the
// renderer changes, so these snapshots come from the real binary, driven under
// a pty by script(1) with a terminal that advertises truecolor.
//
// The rendered SVGs are committed because the docs site builds on Linux, where
// the macOS-only binary cannot run. They are not checkable in CI the way the
// CLI reference is: every frame carries a wall clock, so two captures never
// match byte for byte. Re-run this script when the renderer changes.
//
// Usage:
//   node scripts/gen-terminal-frames.mjs     # capture and write the SVGs
//
// Set GUARANATE_BIN to use an already-built binary.

import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(docsDir, '..');
const outputDir = join(docsDir, 'src/assets/frames');

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
 * Terminal columns a string occupies.
 *
 * Only emoji matter here: the mascot leaf in the header takes two cells, so
 * counting code points would place everything after it one column early.
 */
function columnWidth(text) {
  let width = 0;
  for (const character of text) {
    const code = character.codePointAt(0);
    width += code >= 0x1f300 && code <= 0x1faff ? 2 : 1;
  }
  return width;
}

const EMOJI = /([\u{1F300}-\u{1FAFF}])/u;

/**
 * One line of a frame as styled runs, each with the column it starts at.
 *
 * Two things are deliberate. Emoji become runs of their own: a text element
 * that mixes them with spaces is shaped with the emoji font throughout by some
 * renderers, which widens every space and pushes the rest of the line out of
 * the grid. And the padding spaces a terminal uses for alignment are dropped,
 * because every run carries its own column — browsers collapse leading and
 * trailing whitespace in SVG text, so relying on it would glue runs together.
 */
function runs(line) {
  const style = { ...DEFAULT_STYLE };
  const result = [];
  let column = 0;
  const pattern = /\u001b\[([0-9;]*)m/g;
  let cursor = 0;
  let match;
  const push = (text) => {
    for (const part of text.split(EMOJI)) {
      if (!part) continue;
      const leading = part.length - part.trimStart().length;
      const trimmed = part.trim();
      if (trimmed) result.push({ text: trimmed, column: column + leading, ...style });
      column += columnWidth(part);
    }
  };
  while ((match = pattern.exec(line)) !== null) {
    push(line.slice(cursor, match.index));
    applySGR(style, match[1].split(';').map((p) => (p === '' ? 0 : Number(p))));
    cursor = pattern.lastIndex;
  }
  push(line.slice(cursor));
  return result;
}

const escapeXML = (text) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const CELL = 8.4; // advance width of the 14px monospace grid
const LINE = 21;
const PAD_X = 18;
const PAD_Y = 22;

/**
 * Renders a frame as a standalone SVG.
 *
 * Runs are positioned by column rather than flowed, so the progress bar stays
 * aligned with the metrics table even if the reader's monospace fallback font
 * measures block glyphs slightly differently.
 */
function svg(frame, { title, background = '#17120f' }) {
  const lines = frame.split('\n');
  const columns = Math.max(...lines.map((line) => columnWidth(line.replace(/\u001b\[[0-9;]*m/g, ''))));
  const width = Math.round(columns * CELL + PAD_X * 2);
  const height = Math.round(lines.length * LINE + PAD_Y * 2);

  const body = lines
    .map((line, row) => {
      const y = PAD_Y + row * LINE + 14;
      const spans = runs(line)
        .filter((run) => run.text.trim() !== '')
        .map((run) => {
          const attrs = [
            `x="${(PAD_X + run.column * CELL).toFixed(1)}"`,
            `y="${y}"`,
            run.color ? `fill="${run.color}"` : null,
            run.bold ? 'font-weight="700"' : null,
            run.dim ? 'opacity="0.55"' : null,
          ]
            .filter(Boolean)
            .join(' ');
          return `<text ${attrs}>${escapeXML(run.text)}</text>`;
        })
        .join('');
      return spans;
    })
    .filter(Boolean)
    .join('\n    ');

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="${escapeXML(title)}">
  <title>${escapeXML(title)}</title>
  ${background ? `<rect width="${width}" height="${height}" rx="12" fill="${background}"/>` : ''}
  <g font-family="'JetBrains Mono Variable', ui-monospace, SFMono-Regular, Menlo, monospace" font-size="14" fill="#e8e2df" xml:space="preserve">
    ${body}
  </g>
</svg>
`;
}

// --- Main ---------------------------------------------------------------------

const binary = resolveBinary();
mkdirSync(outputDir, { recursive: true });

function write(name, frame, title, options = {}) {
  const path = join(outputDir, name);
  writeFileSync(path, svg(frame, { title, ...options }));
  process.stdout.write(`Wrote ${relative(repoRoot, path)}\n`);
}

// A timed session: captured 12s into a 20s run, so the bar is partly filled,
// and again at the end for the completion card.
const timed = frames(
  await capture([binary, '20', '--reason', 'release build'], { runFor: 20_000, interrupt: false }),
);
write('timed-session.svg', timed[12], 'Guaranate running a timed session: a progress bar at 65%, elapsed, remaining, and end time');
write('completion-card.svg', timed.at(-1), 'Guaranate after a timed session: a full progress bar and a summary card');

// The same frame again for the landing page, where it sits inside a terminal
// window the page draws itself — so this one gets no background of its own.
write(
  'hero-session.svg',
  timed[12],
  'Guaranate running a timed session: a progress bar at 65%, elapsed, remaining, and end time',
  { background: null },
);

// A watch session needs something to watch: a sleep of our own, which
// outlives the capture and is cleaned up afterwards.
const watched = spawn('sleep', ['120'], { stdio: 'ignore' });
try {
  const watch = frames(await capture([binary, '--watch', String(watched.pid)], { runFor: 4_000 }));
  write('watch-session.svg', watch.at(-2), 'Guaranate watching a running process: a spinner, elapsed time, and the watched pid');
} finally {
  spawnSync('kill', [String(watched.pid)]);
}
