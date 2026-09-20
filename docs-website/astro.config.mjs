import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import { withZephyr } from 'zephyr-astro-integration';

const repo = 'https://github.com/ryok90/guaranate';

// Canonical site URL: the production domain attached in Zephyr (Tags &
// Environments), which enables canonical URLs and the sitemap. `DOCS_SITE_URL`
// overrides it; preview builds keep pointing canonical URLs at production
// rather than at their own immutable Zephyr version URL.
const site = process.env.DOCS_SITE_URL ?? 'https://guaranate.dev';

// Social cards need an absolute image URL — relative paths are not unfurled.
// Starlight emits `twitter:card: summary_large_image` but no image of its own,
// which is why link previews came up blank.
const socialCard = new URL('/brand/social-card.png', site).href;
const socialCardAlt =
  'The Guaranate guaraná berry mascot in a terminal window, beside the wordmark and the tagline "Keep your Mac awake with native macOS power assertions."';

const socialCardMeta = [
  { property: 'og:image', content: socialCard },
  { property: 'og:image:type', content: 'image/png' },
  { property: 'og:image:width', content: '1200' },
  { property: 'og:image:height', content: '630' },
  { property: 'og:image:alt', content: socialCardAlt },
  { name: 'twitter:image', content: socialCard },
  { name: 'twitter:image:alt', content: socialCardAlt },
].map((attrs) => ({ tag: 'meta', attrs }));

// Zephyr deploys during the build, and with no credentials at all it waits on an
// interactive auth flow until that times out — minutes added to a build that only
// needs verifying. CI sets SKIP_ZEPHYR=true when no `ZE_SECRET_TOKEN` is set,
// which is the case for pull requests from forks: they cannot read repository
// secrets, so they build-verify the site instead of deploying it.
const deploy = process.env.SKIP_ZEPHYR !== 'true';

export default defineConfig({
  site,
  // Required: the Zephyr integration supports Astro's SSG mode only.
  output: 'static',
  integrations: [
    starlight({
      title: 'Guaranate',
      description:
        'Guaranate keeps your Mac awake with native macOS power assertions — friendlier and more scriptable than caffeinate.',
      logo: { src: './src/assets/brand/mascot.png', alt: 'The Guaranate guaraná berry mascot' },
      favicon: '/favicon.png',
      head: socialCardMeta,
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      editLink: { baseUrl: `${repo}/edit/main/docs-website/` },
      lastUpdated: true,
      customCss: [
        '@fontsource-variable/space-grotesk',
        '@fontsource-variable/jetbrains-mono',
        './src/styles/theme.css',
      ],
      sidebar: [
        {
          label: 'Start here',
          items: [
            { slug: 'guides/install' },
            { slug: 'guides/timed-sessions' },
            { slug: 'guides/process-sessions' },
            { slug: 'guides/how-it-works' },
          ],
        },
        {
          label: 'Reference',
          items: [{ slug: 'reference/cli' }, { slug: 'reference/roadmap' }],
        },
      ],
    }),
    ...(deploy ? [withZephyr()] : []),
  ],
});
