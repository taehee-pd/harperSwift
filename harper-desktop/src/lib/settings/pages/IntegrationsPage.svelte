<!-- Modified in this fork (taehee-pd/harperSwift): titled Apps, macOS-style list and switches,
     the Add App sheet closes as soon as an app is picked, and focus returns to Add App…. -->
<script lang="ts">
import { CloseIcon, IconButton, Toggle } from 'components';
import { onMount, tick } from 'svelte';
import { Client, type Integration } from '$lib/client';
import AppIcon from '../components/AppIcon.svelte';
import AppPickerModal from '../components/AppPickerModal.svelte';

interface IntegrationRow extends Integration {
	name: string;
}

let integrations: Integration[] = [];
let integrationApps: IntegrationRow[] = [];
let integrationsError = '';
let isIntegrationsLoading = true;
let isIntegrationsSaving = false;
let autoEnableNewApps = false;
let isAutoEnableLoading = true;
let isAutoEnableSaving = false;
let autoEnableError = '';
let appPickerOpen = false;
let addAppButton: HTMLButtonElement;

$: existingBundleIds = integrations.map((integration) => integration.bundle_id);

onMount(() => {
	const refresh = () => {
		if (!isIntegrationsSaving) void loadIntegrations();
		if (!isAutoEnableSaving) void loadAutoEnableNewApps();
	};
	refresh();
	window.addEventListener('focus', refresh);
	return () => window.removeEventListener('focus', refresh);
});

async function loadAutoEnableNewApps() {
	isAutoEnableLoading = true;
	autoEnableError = '';
	try {
		autoEnableNewApps = await Client.getAutoEnableNewApps();
	} catch (error) {
		autoEnableError = `Unable to load automatic app enablement: ${error}`;
	} finally {
		isAutoEnableLoading = false;
	}
}

async function setAutoEnableNewApps(enabled: boolean) {
	const previous = autoEnableNewApps;
	autoEnableNewApps = enabled;
	isAutoEnableSaving = true;
	autoEnableError = '';
	try {
		await Client.setAutoEnableNewApps(enabled);
	} catch (error) {
		autoEnableNewApps = previous;
		autoEnableError = `Unable to save automatic app enablement: ${error}`;
	} finally {
		isAutoEnableSaving = false;
	}
}

async function loadIntegrations() {
	isIntegrationsLoading = true;
	integrationsError = '';

	try {
		integrations = await Client.getIntegrations();
		integrationApps = integrations.map(toIntegrationRow);
	} catch (error) {
		integrationsError = `Unable to load integrations: ${error}`;
	} finally {
		isIntegrationsLoading = false;
	}
}

function toIntegrationRow(integration: Integration): IntegrationRow {
	return {
		...integration,
		name: integration.display_name,
	};
}

async function setIntegrationEnabled(bundleId: string, enabled: boolean) {
	const previousIntegrations = integrations;
	const previousIntegrationApps = integrationApps;

	integrations = integrations.map((integration) =>
		integration.bundle_id === bundleId ? { ...integration, enabled } : integration,
	);
	integrationApps = integrationApps.map((app) =>
		app.bundle_id === bundleId ? { ...app, enabled } : app,
	);
	isIntegrationsSaving = true;
	integrationsError = '';

	try {
		await Client.setIntegrationEnabled(bundleId, enabled);
	} catch (error) {
		integrations = previousIntegrations;
		integrationApps = previousIntegrationApps;
		integrationsError = `Unable to update integration: ${error}`;
	} finally {
		isIntegrationsSaving = false;
	}
}

async function removeIntegration(bundleId: string) {
	const previousIntegrations = integrations;
	const previousIntegrationApps = integrationApps;

	integrations = integrations.filter((integration) => integration.bundle_id !== bundleId);
	integrationApps = integrationApps.filter((app) => app.bundle_id !== bundleId);
	isIntegrationsSaving = true;
	integrationsError = '';

	try {
		await Client.removeIntegration(bundleId);
	} catch (error) {
		integrations = previousIntegrations;
		integrationApps = previousIntegrationApps;
		integrationsError = `Unable to remove integration: ${error}`;
	} finally {
		isIntegrationsSaving = false;
	}
}

async function addIntegration(bundleId: string) {
	const trimmedBundleId = bundleId.trim();

	if (
		!trimmedBundleId ||
		integrations.some((integration) => integration.bundle_id === trimmedBundleId)
	) {
		return;
	}

	const previousIntegrations = integrations;
	const previousIntegrationApps = integrationApps;

	integrations = [
		...integrations,
		{ bundle_id: trimmedBundleId, enabled: true, display_name: trimmedBundleId },
	];
	integrationApps = integrations.map(toIntegrationRow);
	isIntegrationsSaving = true;
	integrationsError = '';

	try {
		await Client.addIntegration(trimmedBundleId);
		await loadIntegrations();
	} catch (error) {
		integrations = previousIntegrations;
		integrationApps = previousIntegrationApps;
		integrationsError = `Unable to add integration: ${error}`;
	} finally {
		isIntegrationsSaving = false;
	}
}

async function closeAppPicker() {
	appPickerOpen = false;
	// Return focus to the button that opened the sheet.
	await tick();
	addAppButton?.focus();
}
</script>

<section>
  <header class="page-header">
    <h1>Apps</h1>
    <p class="page-lede">Harper checks your writing only in the apps turned on here.</p>
  </header>

  <div class="form-section">
    <div class="form-group" style="--row-inset: 54px">
      {#if isIntegrationsLoading && integrationApps.length === 0}
        <div class="empty" role="status">Loading…</div>
      {:else if integrationApps.length === 0}
        <div class="empty">
          <strong>No apps yet</strong>
          Add an app to have Harper check your writing in it.
        </div>
      {:else}
        {#each integrationApps as app (app.bundle_id)}
          <div class="list-row app">
            <AppIcon bundleId={app.bundle_id} name={app.name} />
            <div class="grow">
              <span class="app-name" id={`app-${app.bundle_id}`}>{app.name}</span>
              <span class="app-bundle">{app.bundle_id}</span>
            </div>
            <IconButton
              danger
              disabled={isIntegrationsLoading || isIntegrationsSaving}
              aria-label={`Remove ${app.name}`}
              title="Remove from the list"
              on:click={() => removeIntegration(app.bundle_id)}
            >
              <CloseIcon className="control-icon" />
            </IconButton>
            <Toggle
              appearance="settings"
              checked={app.enabled}
              disabled={isIntegrationsLoading || isIntegrationsSaving}
              aria-labelledby={`app-${app.bundle_id}`}
              on:click={() => setIntegrationEnabled(app.bundle_id, !app.enabled)}
            />
          </div>
        {/each}
      {/if}
    </div>
    {#if integrationsError}
      <p class="form-error" role="alert">{integrationsError}</p>
    {/if}

    <div class="actions-row">
      <button
        bind:this={addAppButton}
        class="button"
        type="button"
        disabled={isIntegrationsLoading}
        on:click={() => (appPickerOpen = true)}
      >Add App…</button>
    </div>
  </div>

  <div class="form-section">
    <h2 class="form-section-title">New apps</h2>
    <div class="form-group">
      <div class="form-row">
        <div class="form-row-text">
          <span class="form-row-label" id="auto-enable-label">Turn on new apps automatically</span>
          <p class="form-row-detail">
            When you write in a new app, Harper adds it here and turns it on. Apps you turned off
            stay off.
          </p>
        </div>
        <Toggle
          appearance="settings"
          checked={autoEnableNewApps}
          disabled={isAutoEnableLoading || isAutoEnableSaving}
          aria-labelledby="auto-enable-label"
          on:click={() => setAutoEnableNewApps(!autoEnableNewApps)}
        />
      </div>
    </div>
    {#if autoEnableError}
      <p class="form-error" role="alert">{autoEnableError}</p>
    {/if}
  </div>
</section>

{#if appPickerOpen}
  <AppPickerModal {existingBundleIds} close={closeAppPicker} add={addIntegration} />
{/if}
