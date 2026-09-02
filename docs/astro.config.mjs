import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import { withZephyr } from 'zephyr-astro-integration';

const repo = 'https://github.com/ryok90/guaranate';

export default defineConfig({
  // Set DOCS_SITE_URL once a canonical domain is wired up in Zephyr (Tags &
  // Environments). Until then every build is served from its own immutable
  // Zephyr version URL, and canonical URLs / sitemap stay off rather than
  // pointing at a domain that does not exist yet.
  site: process.env.DOCS_SITE_URL,
  // Required: the Zephyr integration supports Astro's SSG mode only.
  output: 'static',
  integrations: [
    starlight({
      title: 'Guaranate',
      description:
        'Guaranate keeps your Mac awake with native macOS power assertions — friendlier and more scriptable than caffeinate.',
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      editLink: { baseUrl: `${repo}/edit/main/docs/` },
      lastUpdated: true,
      sidebar: [
        {
          label: 'Start here',
          items: [
            { slug: 'guides/install' },
            { slug: 'guides/timed-sessions' },
            { slug: 'guides/how-it-works' },
          ],
        },
        {
          label: 'Reference',
          items: [{ slug: 'reference/cli' }, { slug: 'reference/roadmap' }],
        },
      ],
    }),
    withZephyr(),
  ],
});
