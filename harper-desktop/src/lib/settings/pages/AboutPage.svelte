<!-- Modified in this fork (taehee-pd/harperSwift): Release Notes and Source Code point at this fork,
     whose versions and updates differ from upstream; issues still go to upstream Harper, since the
     fork has none. macOS-style layout. -->
<script lang="ts">
import { openUrl } from '@tauri-apps/plugin-opener';
import { Logo } from 'components';
import { onMount } from 'svelte';
import { Client } from '$lib/client';

const FORK_URL = 'https://github.com/taehee-pd/harperSwift';
const UPSTREAM_URL = 'https://github.com/Automattic/harper';
const ISSUE_URL = 'https://github.com/Automattic/harper/issues/new/choose';

let currentVersion = '';

$: releaseNotesUrl = currentVersion
	? `${FORK_URL}/releases/tag/v${currentVersion}`
	: `${FORK_URL}/releases/latest`;

onMount(() => {
	void loadCurrentVersion();
});

async function loadCurrentVersion() {
	try {
		currentVersion = await Client.getCurrentVersion();
	} catch (error) {
		console.error('Unable to load Harper Desktop version.', error);
	}
}
</script>

<section class="about">
  <div class="about-mark" aria-hidden="true"><Logo /></div>
  <h1>Harper for Mac</h1>
  <p class="about-version">{currentVersion ? `Version ${currentVersion}` : '\u00a0'}</p>
  <p class="about-copy">
    An open-source grammar checker that runs entirely on your Mac. No account, no tracking, no
    cloud.
  </p>
  <div class="actions-row center">
    <button class="button" type="button" on:click={() => void openUrl(releaseNotesUrl)}>Release Notes</button>
    <button class="button" type="button" on:click={() => void openUrl(FORK_URL)}>Source Code</button>
    <button class="button" type="button" on:click={() => void openUrl(ISSUE_URL)}>Report an Issue</button>
  </div>
  <div class="about-footer">
    Based on <a href={UPSTREAM_URL} on:click|preventDefault={() => void openUrl(UPSTREAM_URL)}>Harper</a>,
    free software released under the Apache 2.0 license.
    <br />
    Copyright 2026 The Harper Contributors.
  </div>
</section>
