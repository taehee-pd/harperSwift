<!-- Added in this fork (taehee-pd/harperSwift): the Clarity suggestions switch and the Apple
     Intelligence status. Shown on macOS only, where Clarity runs. -->
<script lang="ts">
import { isTauri } from '@tauri-apps/api/core';
import { platform } from '@tauri-apps/plugin-os';
import { Checkbox, CheckIcon, SettingRow } from 'components';
import { onMount } from 'svelte';
import { type ClaritySettings, Client } from '$lib/client';

/** How often to refresh the status while settings are open. The highlighter reports changes
 * about once a second. */
const STATUS_REFRESH_MS = 3_000;

const isMacOS = isTauri() && platform() === 'macos';

let settings: ClaritySettings | null = null;
let isSaving = false;
let error = '';

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

async function load() {
	try {
		settings = await Client.getClaritySettings();
		error = '';
	} catch (loadError) {
		error = `Unable to load Clarity settings: ${loadError}`;
	}
}

async function setEnabled(enabled: boolean) {
	if (settings == null) {
		return;
	}

	const previous = settings;
	settings = { ...settings, enabled };
	isSaving = true;
	error = '';

	try {
		await Client.setClarityEnabled(enabled);
	} catch (saveError) {
		settings = previous;
		error = `Unable to save Clarity setting: ${saveError}`;
	} finally {
		isSaving = false;
	}
}
</script>

{#if isMacOS}
  <div class="divider"></div>

  <div class="stanza">
    <div class="eyebrow">Clarity</div>
    <div class="rows">
      <SettingRow top>
        <strong>Clarity suggestions</strong>
        <p>
          Apple Intelligence suggests clearer, shorter wording for sentences that have no spelling or
          grammar issues. Suggestions are made on this Mac; your text never leaves it.
        </p>
        <p class="result-summary">{settings?.status ?? 'Loading status...'}</p>
        <Checkbox
          slot="control"
          appearance="settings"
          checked={settings != null && settings.enabled && settings.available}
          disabled={settings == null || !settings.available || isSaving}
          on:click={() => settings && setEnabled(!settings.enabled)}
        >
          {#if settings != null && settings.enabled && settings.available}<CheckIcon
              className="control-icon"
            />{/if}
        </Checkbox>
      </SettingRow>
    </div>
    {#if error}
      <p class="result-summary">{error}</p>
    {:else if isSaving}
      <p class="result-summary">Saving Clarity setting...</p>
    {/if}
  </div>
{/if}
