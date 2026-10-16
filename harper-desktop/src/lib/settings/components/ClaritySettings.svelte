<!-- Added in this fork (taehee-pd/harperSwift): the Clarity suggestions switch and the Apple
     Intelligence status. Shown on macOS only, where Clarity runs. -->
<script lang="ts">
import { isTauri } from '@tauri-apps/api/core';
import { platform } from '@tauri-apps/plugin-os';
import { Toggle } from 'components';
import { onMount } from 'svelte';
import { type ClaritySettings, Client } from '$lib/client';

/** How often to refresh the status while settings are open. The highlighter reports changes
 * about once a second. */
const STATUS_REFRESH_MS = 3_000;

const isMacOS = isTauri() && platform() === 'macos';

let settings: ClaritySettings | null = null;
let isSaving = false;
let loadError = '';
let saveError = '';
/** Bumped by every save, so a status read that started before it cannot undo the switch. */
let saveCount = 0;

onMount(() => {
	if (!isMacOS) {
		return;
	}

	void load();
	const interval = window.setInterval(() => {
		if (!isSaving) {
			void load();
		}
	}, STATUS_REFRESH_MS);

	return () => window.clearInterval(interval);
});

/** The status starts with its state ("Ready: ...", "Paused: ..."); the dot shows that state while
 * Clarity is on. */
$: statusTone = !settings?.enabled
	? ''
	: settings.status.startsWith('Ready')
		? 'ready'
		: settings?.status.startsWith('Paused')
			? 'paused'
			: '';

async function load() {
	const startedAt = saveCount;

	try {
		const loaded = await Client.getClaritySettings();
		if (startedAt === saveCount) {
			settings = loaded;
			loadError = '';
		}
	} catch (error) {
		loadError = `Unable to load Clarity settings: ${error}`;
	}
}

async function setEnabled(enabled: boolean) {
	if (settings == null) {
		return;
	}

	const previous = settings;
	settings = { ...settings, enabled };
	saveCount += 1;
	isSaving = true;
	saveError = '';

	try {
		await Client.setClarityEnabled(enabled);
	} catch (error) {
		settings = previous;
		saveError = `Unable to save Clarity setting: ${error}`;
	} finally {
		isSaving = false;
	}
}
</script>

{#if isMacOS}
  <div class="form-section">
    <h2 class="form-section-title">Apple Intelligence</h2>
    <div class="form-group">
      <div class="form-row">
        <div class="form-row-text">
          <span class="form-row-label" id="clarity-label">Clarity suggestions</span>
          <p class="form-row-detail">
            Suggests clearer, shorter wording for sentences that have no spelling or grammar issues.
            Suggestions are made on this Mac; your text never leaves it.
          </p>
          <p class="status-line">
            <span class={`status-dot ${statusTone}`} aria-hidden="true"></span>
            {settings?.status ?? 'Checking…'}
          </p>
        </div>
        <Toggle
          appearance="settings"
          checked={settings != null && settings.enabled && settings.available}
          disabled={settings == null || !settings.available || isSaving}
          aria-labelledby="clarity-label"
          on:click={() => settings && setEnabled(!settings.enabled)}
        />
      </div>
    </div>
    {#if saveError || loadError}
      <p class="form-error" role="alert">{saveError || loadError}</p>
    {/if}
  </div>
{/if}
