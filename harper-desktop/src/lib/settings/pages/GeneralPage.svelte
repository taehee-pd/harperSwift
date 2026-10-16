<!-- Modified in this fork (taehee-pd/harperSwift): adds the Clarity settings section on macOS, and
     redesigns the page as grouped macOS sections with switches. The menu bar checkbox, which did
     nothing yet, is gone, and saving no longer shows status text. -->
<script lang="ts">
import { Button, Input, Select, Toggle } from 'components';
import type { Dialect } from 'harper.js';
import { onMount } from 'svelte';
import { Client } from '$lib/client';
import ClaritySettings from '../components/ClaritySettings.svelte';
import { DIALECT_OPTIONS } from '../settings-data';

const DialectValue = {
	American: 0,
	British: 1,
	Australian: 2,
	Canadian: 3,
	Indian: 4,
} as const;

let launchAtStartup = false;
let autoUpdate = true;
let dialect = 'american';
let isDialectLoading = true;
let isDialectSaving = false;
let dialectError = '';
let isLaunchAtStartupLoading = true;
let isLaunchAtStartupSaving = false;
let launchAtStartupError = '';
let isAutoUpdateLoading = true;
let isAutoUpdateSaving = false;
let isCheckingForUpdates = false;
let autoUpdateError = '';
let updateStatus = '';
let currentVersion = '';
let latestVersion = '';
let debounceMs = 0;
let debounceMsInput = '0';
let isDebounceLoading = true;
let isDebounceSaving = false;
let debounceError = '';

onMount(() => {
	void loadDialect();
	void loadLaunchAtStartup();
	void loadAutoUpdate();
	void loadUpdateVersions();
	void loadDebounceMs();

	const refreshSettings = () => {
		if (!isDialectSaving) {
			void loadDialect();
		}

		if (!isLaunchAtStartupSaving) {
			void loadLaunchAtStartup();
		}

		if (!isAutoUpdateSaving) {
			void loadAutoUpdate();
		}

		if (!isCheckingForUpdates) {
			void loadUpdateVersions();
		}

		if (!isDebounceSaving) {
			void loadDebounceMs();
		}
	};

	window.addEventListener('focus', refreshSettings);

	return () => {
		window.removeEventListener('focus', refreshSettings);
	};
});

async function loadDialect() {
	isDialectLoading = true;
	dialectError = '';

	try {
		dialect = dialectToSettingsValue(await Client.getDialect());
	} catch (error) {
		dialectError = `Unable to load dialect: ${error}`;
	} finally {
		isDialectLoading = false;
	}
}

async function setDialect(value: string) {
	const previousDialect = dialect;

	dialect = value;
	isDialectSaving = true;
	dialectError = '';

	try {
		await Client.setDialect(settingsValueToDialect(value));
	} catch (error) {
		dialect = previousDialect;
		dialectError = `Unable to save dialect: ${error}`;
	} finally {
		isDialectSaving = false;
	}
}

async function loadLaunchAtStartup() {
	isLaunchAtStartupLoading = true;
	launchAtStartupError = '';

	try {
		launchAtStartup = await Client.getLaunchAtStartup();
	} catch (error) {
		launchAtStartupError = `Unable to load startup setting: ${error}`;
	} finally {
		isLaunchAtStartupLoading = false;
	}
}

async function setLaunchAtStartup(enabled: boolean) {
	const previousLaunchAtStartup = launchAtStartup;

	launchAtStartup = enabled;
	isLaunchAtStartupSaving = true;
	launchAtStartupError = '';

	try {
		await Client.setLaunchAtStartup(enabled);
	} catch (error) {
		launchAtStartup = previousLaunchAtStartup;
		launchAtStartupError = `Unable to save startup setting: ${error}`;
	} finally {
		isLaunchAtStartupSaving = false;
	}
}

async function loadAutoUpdate() {
	isAutoUpdateLoading = true;
	autoUpdateError = '';

	try {
		autoUpdate = await Client.getAutoUpdate();
	} catch (error) {
		autoUpdateError = `Unable to load update setting: ${error}`;
	} finally {
		isAutoUpdateLoading = false;
	}
}

async function setAutoUpdate(enabled: boolean) {
	const previousAutoUpdate = autoUpdate;

	autoUpdate = enabled;
	isAutoUpdateSaving = true;
	autoUpdateError = '';
	updateStatus = '';

	try {
		await Client.setAutoUpdate(enabled);
	} catch (error) {
		autoUpdate = previousAutoUpdate;
		autoUpdateError = `Unable to save update setting: ${error}`;
	} finally {
		isAutoUpdateSaving = false;
	}
}

async function loadUpdateVersions() {
	try {
		const [current, latest] = await Promise.all([
			Client.getCurrentVersion(),
			Client.getLatestVersion(),
		]);
		currentVersion = current;
		latestVersion = latest;
	} catch (error) {
		console.error('Unable to load update versions.', error);
	}
}

async function checkForUpdates() {
	isCheckingForUpdates = true;
	autoUpdateError = '';
	updateStatus = '';

	try {
		const result = await Client.updateToLatest();
		if (result.status === 'error') {
			autoUpdateError = result.message;
		} else {
			updateStatus = result.message;
		}

		if (result.latestVersion != null) {
			latestVersion = result.latestVersion;
		}

		currentVersion = result.currentVersion ?? (await Client.getCurrentVersion());
	} catch (error) {
		autoUpdateError = `Unable to check for updates: ${error}`;
		updateStatus = '';
	} finally {
		isCheckingForUpdates = false;
	}
}

async function loadDebounceMs() {
	isDebounceLoading = true;
	debounceError = '';

	try {
		debounceMs = await Client.getDebounceMs();
		debounceMsInput = String(debounceMs);
	} catch (error) {
		debounceError = `Unable to load debounce delay: ${error}`;
	} finally {
		isDebounceLoading = false;
	}
}

async function saveDebounceMs() {
	// An emptied field means "never mind", not 0 ms.
	if (String(debounceMsInput ?? '').trim() === '') {
		debounceMsInput = String(debounceMs);
		return;
	}

	const parsedDebounceMs = Number(debounceMsInput);

	if (!Number.isInteger(parsedDebounceMs) || parsedDebounceMs < 0) {
		debounceError = 'Debounce delay must be a non-negative whole number.';
		debounceMsInput = String(debounceMs);
		return;
	}

	const previousDebounceMs = debounceMs;
	debounceMs = parsedDebounceMs;
	debounceMsInput = String(parsedDebounceMs);
	isDebounceSaving = true;
	debounceError = '';

	try {
		await Client.setDebounceMs(parsedDebounceMs);
	} catch (error) {
		debounceMs = previousDebounceMs;
		debounceMsInput = String(previousDebounceMs);
		debounceError = `Unable to save debounce delay: ${error}`;
	} finally {
		isDebounceSaving = false;
	}
}

/** One line under the version: the last check's result, or whether a newer version exists. */
$: updateSummary = isCheckingForUpdates
	? 'Looking for a newer version…'
	: autoUpdateError
		? ''
		: updateStatus ||
			(latestVersion && currentVersion && latestVersion !== currentVersion
				? `Version ${latestVersion} is available.`
				: latestVersion
					? 'Harper is up to date.'
					: '');

function dialectToSettingsValue(dialect: Dialect): string {
	switch (dialect) {
		case DialectValue.British:
			return 'british';
		case DialectValue.Canadian:
			return 'canadian';
		case DialectValue.Australian:
			return 'australian';
		case DialectValue.Indian:
			return 'indian';
		default:
			return 'american';
	}
}

function settingsValueToDialect(value: string): Dialect {
	switch (value) {
		case 'british':
			return DialectValue.British as Dialect;
		case 'canadian':
			return DialectValue.Canadian as Dialect;
		case 'australian':
			return DialectValue.Australian as Dialect;
		case 'indian':
			return DialectValue.Indian as Dialect;
		default:
			return DialectValue.American as Dialect;
	}
}
</script>

<section>
  <header class="page-header">
    <h1>General</h1>
  </header>

  <div class="form-section">
    <h2 class="form-section-title">Writing</h2>
    <div class="form-group">
      <div class="form-row">
        <div class="form-row-text">
          <label class="form-row-label" for="dialect">English dialect</label>
          <p class="form-row-detail">Harper checks spelling and grammar for this variety of English.</p>
        </div>
        <Select
          unstyled
          id="dialect"
          class="select"
          disabled={isDialectLoading || isDialectSaving}
          bind:value={dialect}
          on:change={(event) => setDialect((event.detail.currentTarget as HTMLSelectElement).value)}
        >
          {#each DIALECT_OPTIONS as option}
            <option value={option.value}>{option.label}</option>
          {/each}
        </Select>
      </div>

      <div class="form-row">
        <div class="form-row-text">
          <label class="form-row-label" for="debounce-ms">Wait after typing</label>
          <p class="form-row-detail">
            How long Harper waits after you stop typing. Use 0 to check right away.
          </p>
        </div>
        <span class="number-field">
          <Input
            unstyled
            id="debounce-ms"
            class="text-field"
            type="number"
            min="0"
            step="50"
            disabled={isDebounceLoading || isDebounceSaving}
            bind:value={debounceMsInput}
            on:change={saveDebounceMs}
          />
          ms
        </span>
      </div>
    </div>
    {#if dialectError}
      <p class="form-error" role="alert">{dialectError}</p>
    {/if}
    {#if debounceError}
      <p class="form-error" role="alert">{debounceError}</p>
    {/if}
  </div>

  <ClaritySettings />

  <div class="form-section">
    <h2 class="form-section-title">Startup and updates</h2>
    <div class="form-group">
      <div class="form-row">
        <div class="form-row-text">
          <span class="form-row-label" id="launch-at-startup-label">Open at login</span>
          <p class="form-row-detail">Harper starts quietly in the menu bar when you log in.</p>
        </div>
        <Toggle
          appearance="settings"
          checked={launchAtStartup}
          disabled={isLaunchAtStartupLoading || isLaunchAtStartupSaving}
          aria-labelledby="launch-at-startup-label"
          on:click={() => setLaunchAtStartup(!launchAtStartup)}
        />
      </div>

      <div class="form-row">
        <div class="form-row-text">
          <span class="form-row-label" id="auto-update-label">Check for updates automatically</span>
          <p class="form-row-detail">Harper looks for a new version once a day.</p>
        </div>
        <Toggle
          appearance="settings"
          checked={autoUpdate}
          disabled={isAutoUpdateLoading || isAutoUpdateSaving}
          aria-labelledby="auto-update-label"
          on:click={() => setAutoUpdate(!autoUpdate)}
        />
      </div>

      <div class="form-row">
        <div class="form-row-text">
          <span class="form-row-label">Version {currentVersion || '…'}</span>
          <p class="form-row-detail" role="status">{updateSummary}</p>
        </div>
        <Button
          unstyled
          class="button"
          type="button"
          state={isCheckingForUpdates ? 'loading' : 'idle'}
          on:click={checkForUpdates}
        >
          {isCheckingForUpdates ? 'Checking…' : 'Check Now'}
        </Button>
      </div>
    </div>
    {#if launchAtStartupError}
      <p class="form-error" role="alert">{launchAtStartupError}</p>
    {/if}
    {#if autoUpdateError}
      <p class="form-error" role="alert">{autoUpdateError}</p>
    {/if}
  </div>
</section>
