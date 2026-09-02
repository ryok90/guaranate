import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import { withZephyr } from 'zephyr-astro-integration';

const repo = 'https://github.com/ryok90/guaranate';

// Zephyr deploys during the build, and with no credentials at all it waits on an
// interactive auth flow until that times out — minutes added to a build that only
// needs verifying. CI sets SKIP_ZEPHYR=true when no `ZE_CI_TOKEN` is available,
// which is the case for pull requests from forks: they cannot read repository
// secrets, so they build-verify the site instead of deploying it.
const deploy = process.env.SKIP_ZEPHYR !== 'true';

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
    ...(deploy ? [withZephyr()] : []),
  ],
});
