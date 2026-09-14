#!/usr/bin/env node
// Generates the CLI reference page from the real binary.
//
// `guaranate --experimental-dump-help` (Swift Argument Parser) is the source of
// truth for every command, argument, flag, and short alias, so the reference
// page cannot drift from the shipped CLI. The generated page is committed
// because the docs site builds on Linux, where the macOS-only binary cannot be
// built. CI re-runs this script with `--check` on macOS — in the Swift
// build/test job, i.e. whenever the binary can actually change — so a stale page
// fails the build.
//
// Usage:
//   node scripts/gen-cli-reference.mjs           # write the reference page
//   node scripts/gen-cli-reference.mjs --check    # fail if the page is stale
//
// Set GUARANATE_BIN to use an already-built binary.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(docsDir, '..');
const outputPath = join(docsDir, 'src/content/docs/reference/cli.md');
const check = process.argv.includes('--check');

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
}

function resolveBinary() {
  if (process.env.GUARANATE_BIN) {
    const explicit = resolve(repoRoot, process.env.GUARANATE_BIN);
    if (!existsSync(explicit)) throw new Error(`GUARANATE_BIN does not exist: ${explicit}`);
    return explicit;
  }

  // Without an explicit binary, build the current sources. Reusing whichever
  // configuration happened to exist first can silently regenerate stale docs.
  process.stderr.write('Building guaranate for CLI reference…\n');
  run('swift', ['build'], { stdio: ['ignore', 'inherit', 'inherit'] });
  return join(repoRoot, '.build/debug/guaranate');
}

// --- Rendering ---------------------------------------------------------------

/** Cell text for a Markdown table: pipes would end the cell. */
const cell = (text) => (text ?? '').replaceAll('|', '\\|');

const isVisible = (argument) => argument.shouldDisplay !== false;

/**
 * ArgumentParser injects its own `help` subcommand into any command that has
 * subcommands. It is parser plumbing rather than part of guaranate's surface —
 * `--help` already documents itself — so it never gets a section.
 */
const visibleSubcommands = (command) =>
  (command.subcommands ?? []).filter((sub) => sub.shouldDisplay !== false && sub.commandName !== 'help');

/** `-d, --display` for flags/options, `<duration>` for positionals. */
function argumentLabel(argument) {
  if (argument.kind === 'positional') return `\`<${argument.valueName}>\``;

  const names = (argument.names ?? []).filter((name) => name.kind !== 'longWithSingleDash');
  const rendered = names.map((name) => (name.kind === 'short' ? `-${name.name}` : `--${name.name}`));
  const value = argument.kind === 'option' ? ` <${argument.valueName}>` : '';
  return rendered.map((name, index) => `\`${name}${index === rendered.length - 1 ? value : ''}\``).join(', ');
}

/** The token a flag/option contributes to the synopsis line. */
function synopsisToken(argument) {
  if (argument.kind === 'positional') {
    const name = `<${argument.valueName}>${argument.isRepeating ? ' ...' : ''}`;
    return argument.isOptional ? `[${name}]` : name;
  }

  const preferred = argument.preferredName ?? argument.names?.[0];
  if (!preferred) return '';
  const name = preferred.kind === 'short' ? `-${preferred.name}` : `--${preferred.name}`;
  const value = argument.kind === 'option' ? ` <${argument.valueName}>` : '';
  return argument.isOptional ? `[${name}${value}]` : `${name}${value}`;
}

function fullName(command) {
  return [...(command.superCommands ?? []), command.commandName].join(' ');
}

function rootUsage(binary) {
  const lines = run(binary, ['--help']).split('\n');
  const start = lines.findIndex((line) => line.startsWith('USAGE: '));
  if (start < 0) return undefined;

  const usage = [lines[start].slice('USAGE: '.length)];
  for (const line of lines.slice(start + 1)) {
    if (!line.trim()) break;
    if (!/^\s/.test(line)) break;
    usage.push(line.trim());
  }
  return usage.join('\n');
}

function synopsis(command) {
  const defaultCommand = visibleSubcommands(command).find(
    (subcommand) => subcommand.commandName === command.defaultSubcommand,
  );
  // A default subcommand's arguments are accepted at the root even though the
  // dump lists them on the child command. Project them here so the published root
  // synopsis documents bare durations, --watch, and --version.
  const args = ((defaultCommand ?? command).arguments ?? []).filter(isVisible);
  const positionals = args.filter((argument) => argument.kind === 'positional');
  const options = args.filter((argument) => argument.kind !== 'positional');
  // A passthrough positional consumes every token after it, including tokens that
  // look like this command's options. Match ArgumentParser's synopsis by putting
  // the parent options first for that command shape.
  const ordered = positionals.some((argument) => argument.parsingStrategy === 'allRemainingInput')
    ? [...options, ...positionals]
    : [...positionals, ...options];
  const tokens = ordered.map(synopsisToken).filter(Boolean);
  if (visibleSubcommands(command).length > 0) tokens.push('[<subcommand>]');
  return [fullName(command), ...tokens].join(' ');
}

function argumentTable(args, { withDefault }) {
  const header = withDefault
    ? ['| Option | Description | Default |', '| --- | --- | --- |']
    : ['| Argument | Description |', '| --- | --- |'];

  const rows = args.map((argument) => {
    const description = cell(argument.abstract) || '—';
    if (!withDefault) {
      const optional = argument.isOptional ? ' *(optional)*' : '';
      return `| ${argumentLabel(argument)}${optional} | ${description} |`;
    }
    const fallback = argument.defaultValue === undefined ? '—' : `\`${cell(argument.defaultValue)}\``;
    return `| ${argumentLabel(argument)} | ${description} | ${fallback} |`;
  });

  return [...header, ...rows].join('\n');
}

/**
 * Discussion text is written for a terminal, where an indented example block is
 * verbatim. Markdown would reflow those lines into one paragraph and collapse
 * their alignment, so each indented block becomes a code fence instead.
 */
function discussionBlocks(discussion) {
  return discussion.split(/\n{2,}/).flatMap((block) => {
    const lines = block.split('\n');
    if (!lines.every((line) => line.startsWith('  '))) return [block, ''];
    return ['```text', ...lines.map((line) => line.slice(2)), '```', ''];
  });
}

function commandSection(command, level, { isDefault = false, usage } = {}) {
  const heading = '#'.repeat(level);
  // The default subcommand's name is optional, which readers need to see next to
  // the heading rather than buried in the command's own discussion.
  const lines = [`${heading} \`${fullName(command)}\`${isDefault ? ' *(default)*' : ''}`, ''];

  if (command.abstract) lines.push(command.abstract, '');
  if (command.discussion) lines.push(...discussionBlocks(command.discussion));

  lines.push('```sh', usage ?? synopsis(command), '```', '');

  const args = (command.arguments ?? []).filter(isVisible);
  const positionals = args.filter((argument) => argument.kind === 'positional');
  const options = args.filter((argument) => argument.kind !== 'positional');

  if (positionals.length > 0) {
    lines.push(argumentTable(positionals, { withDefault: false }), '');
  }
  if (options.length > 0) {
    lines.push(argumentTable(options, { withDefault: true }), '');
  }

  for (const sub of visibleSubcommands(command)) {
    lines.push(commandSection(sub, level + 1, { isDefault: sub.commandName === command.defaultSubcommand }));
  }

  return lines.join('\n');
}

function page({ command, version, usage }) {
  const generator = relative(repoRoot, fileURLToPath(import.meta.url));
  return [
    '---',
    'title: CLI reference',
    'description: Every command, argument, flag, and short alias accepted by the guaranate binary.',
    '---',
    '',
    `<!-- Generated by \`${generator}\`. Do not edit by hand. -->`,
    '',
    `Generated from \`guaranate --experimental-dump-help\` for **guaranate ${version}**, so`,
    'every documented flag and short alias matches the shipped binary.',
    '',
    commandSection(command, 2, { usage }),
  ].join('\n');
}

// --- Main -------------------------------------------------------------------

const binary = resolveBinary();
const dump = JSON.parse(run(binary, ['--experimental-dump-help']));
const version = run(binary, ['--version']).trim();
const rendered = page({ command: dump.command, version, usage: rootUsage(binary) });

if (check) {
  const committed = existsSync(outputPath) ? readFileSync(outputPath, 'utf8') : '';
  if (committed === rendered) {
    process.stdout.write(`✓ ${relative(repoRoot, outputPath)} matches guaranate ${version}\n`);
    process.exit(0);
  }
  process.stderr.write(
    `::error::${relative(repoRoot, outputPath)} is stale for guaranate ${version}. ` +
      'Run `npm run gen:cli` in docs-website/ and commit the result.\n'
  );
  process.exit(1);
}

writeFileSync(outputPath, rendered);
process.stdout.write(`Wrote ${relative(repoRoot, outputPath)} for guaranate ${version}\n`);
