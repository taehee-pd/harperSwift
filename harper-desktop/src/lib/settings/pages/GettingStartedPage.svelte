<!-- Modified in this fork (taehee-pd/harperSwift): plainer copy, clearer status lines, and the
     Accessibility step notices the grant by itself instead of waiting for a Recheck click. -->
<script lang="ts">
import { isTauri } from '@tauri-apps/api/core';
import { platform } from '@tauri-apps/plugin-os';
import { Button, CheckIcon, SlideDeck } from 'components';
import { onDestroy, onMount, tick } from 'svelte';
import { type AccessibilityPermissionStatus, Client, type Integration } from '$lib/client';
import AppIcon from '../components/AppIcon.svelte';

/** Slide identities determine setup gates; only the welcome and test drive need no action. */
type OnboardingSlide = {
	id: 'welcome' | 'accessibility' | 'integration' | 'test-drive' | 'ready';
	title: string;
	lede: string;
};

/** How often to recheck Accessibility access while the user is in System Settings. */
const PERMISSION_POLL_MS = 1_000;

const allSlides: OnboardingSlide[] = [
	{
		id: 'welcome',
		title: 'Welcome to Harper',
		lede: 'Harper checks your spelling and grammar in the apps you already write in.\n\nSetup takes about a minute.',
	},
	{
		id: 'accessibility',
		title: 'Allow Accessibility access',
		lede: 'Harper reads what you type so it can underline mistakes, and writes your fixes back. macOS asks you to allow this in Privacy & Security.\n\nYour writing never leaves this Mac.',
	},
	{
		id: 'integration',
		title: 'Turn on Harper in TextEdit',
		lede: 'Harper checks only the apps you turn on. Start with TextEdit; you can add more apps later in Settings.',
	},
	{
		id: 'test-drive',
		title: 'Try it',
		lede: 'Open TextEdit and type “This is an test.”\n\nHarper underlines the mistake. Click the underline to see the fix.',
	},
	{
		id: 'ready',
		title: 'You’re all set',
		lede: 'Harper runs in the menu bar and checks your writing in the apps you turn on.\n\nYou can change apps, rules, and your dictionary anytime in Settings.',
	},
];

export let onComplete: () => void;

let step = 0;
let isMacOS = false;
let accessibilityStatus: AccessibilityPermissionStatus | null = null;
let setupError = '';
let isPreparingService = true;
let hasRequestedAccessibility = false;
let integrations: Integration[] = [];
let integrationsError = '';
let isLoadingIntegrations = true;
let isEnablingTextEdit = false;
let isLaunchingTextEdit = false;
let testDriveError = '';
let isCompletingOnboarding = false;
let onboardingError = '';
let permissionPoll: number | undefined;

$: slides = allSlides.filter((slide) => slide.id !== 'accessibility' || isMacOS);
$: textEditIntegration = integrations.find((item) => item.bundle_id === 'com.apple.TextEdit');
$: isTextEditEnabled = textEditIntegration?.enabled === true;
$: accessibilityReady =
	(!isMacOS || accessibilityStatus === 'Granted') && !isPreparingService && !setupError;
$: integrationReady =
	isTextEditEnabled && !isLoadingIntegrations && !isEnablingTextEdit && !integrationsError;
$: nextDisabled = !canAdvance(slides[step].id, accessibilityReady, integrationReady, isMacOS);

onMount(() => {
	// Use the native platform in Tauri; user-agent detection is only for browser previews.
	isMacOS = isTauri() ? platform() === 'macos' : navigator.userAgent.includes('Macintosh');
	void prepareService();
	void loadIntegrations();
});

onDestroy(() => window.clearInterval(permissionPoll));

/** While this step waits for access, watch for it to be granted, so coming back from System
 * Settings is enough, however the user got there; Check Again is only a fallback. */
$: if (
	slides[step]?.id === 'accessibility' &&
	!accessibilityReady &&
	accessibilityStatus === 'NotGranted'
) {
	startPermissionPoll();
} else {
	stopPermissionPoll();
}

function startPermissionPoll() {
	if (permissionPoll !== undefined) return;
	permissionPoll = window.setInterval(() => void checkPermissionGranted(), PERMISSION_POLL_MS);
}

/** A finished step removes its button; keep keyboard focus on the slide instead of losing it. */
async function keepFocusOnSlide() {
	await tick();
	if (document.activeElement == null || document.activeElement === document.body) {
		document.getElementById('step-heading')?.focus();
	}
}

function stopPermissionPoll() {
	window.clearInterval(permissionPoll);
	permissionPoll = undefined;
}

async function checkPermissionGranted() {
	if (isPreparingService) return;

	try {
		if ((await Client.getAccessibilityPermissionStatus()) === 'Granted') {
			stopPermissionPoll();
			await prepareService();
		}
	} catch {
		// Keep waiting; Check Again stays available.
	}
}

/** Gate service startup on Welcome outside macOS, or on Accessibility on macOS; the trial is optional. */
function canAdvance(
	slide: OnboardingSlide['id'],
	accessReady: boolean,
	appReady: boolean,
	needsPermission: boolean,
) {
	if (slide === 'welcome') return needsPermission || accessReady;
	if (slide === 'accessibility') return accessReady;
	return accessReady && appReady;
}

async function loadIntegrations() {
	isLoadingIntegrations = true;
	integrationsError = '';

	try {
		integrations = await Client.getIntegrations();
	} catch (error) {
		integrationsError = `Unable to load integrations: ${error}`;
	} finally {
		isLoadingIntegrations = false;
	}
}

async function enableTextEditForSetup() {
	if (!accessibilityReady || isLoadingIntegrations || isEnablingTextEdit) return;
	isEnablingTextEdit = true;
	integrationsError = '';

	try {
		if (textEditIntegration) {
			await Client.setIntegrationEnabled('com.apple.TextEdit', true);
		} else {
			await Client.addIntegration('com.apple.TextEdit');
		}
		await loadIntegrations();
		await keepFocusOnSlide();
	} catch (error) {
		integrationsError = `Unable to enable TextEdit: ${error}`;
	} finally {
		isEnablingTextEdit = false;
	}
}

async function launchTextEditForTestDrive() {
	if (!accessibilityReady || !integrationReady || isLaunchingTextEdit) return;
	isLaunchingTextEdit = true;
	testDriveError = '';

	try {
		await Client.launchApp('com.apple.TextEdit');
	} catch (error) {
		testDriveError = `Unable to launch TextEdit: ${error}`;
	} finally {
		isLaunchingTextEdit = false;
	}
}

/** Persist completion only after mandatory setup; leave the deck only when the save succeeds. */
async function completeOnboarding() {
	if (!accessibilityReady || !integrationReady || isCompletingOnboarding) return;
	isCompletingOnboarding = true;
	onboardingError = '';

	try {
		await Client.setOnboardingCompleted(true);
		onComplete();
	} catch (error) {
		onboardingError = `Unable to complete onboarding: ${error}`;
	} finally {
		isCompletingOnboarding = false;
	}
}

/** Start Harper on every platform, checking or requesting Accessibility permission only on macOS. */
async function prepareService(request = false) {
	isPreparingService = true;
	setupError = '';
	// The last known status stays while checking, so the waiting message does not blink away.

	try {
		if (isMacOS) {
			if (request) {
				// Set first, so a request that times out still shows the waiting message.
				hasRequestedAccessibility = true;
				accessibilityStatus = await Client.requestAccessibilityPermission();
			} else {
				accessibilityStatus = await Client.getAccessibilityPermissionStatus();
			}
		}

		if (
			(!isMacOS || accessibilityStatus === 'Granted') &&
			!(await Client.startHighlighterService())
		) {
			throw new Error('The Harper service did not start. Please try again.');
		}
	} catch (error) {
		setupError = `Unable to ${isMacOS ? 'set up Accessibility' : 'start Harper'}: ${error}`;
	} finally {
		isPreparingService = false;
	}

	// Reactive values update after this function returns, so check the inputs directly.
	if ((!isMacOS || accessibilityStatus === 'Granted') && !setupError) {
		await keepFocusOnSlide();
	}
}
</script>

<div class="onboarding-shell">
  <SlideDeck
    title={slides[step].title}
    lede={slides[step].lede}
    slideProgress={step / (slides.length - 1)}
    {nextDisabled}
    onBack={() => {
      if (!isCompletingOnboarding) step--;
    }}
    onNext={() => step++}
  >
    {#if slides[step].id === 'welcome' && !isMacOS}
      {#if isPreparingService}
        <div class="onboarding-actions">
          <p class="onboarding-status waiting" role="status">
            <span class="onboarding-spinner" aria-hidden="true"></span>Starting Harper…
          </p>
        </div>
      {:else if setupError}
        <div class="onboarding-actions">
          <p class="onboarding-status error" role="alert">{setupError}</p>
          <Button on:click={() => prepareService()}>Try Again</Button>
        </div>
      {/if}
    {:else if slides[step].id === 'accessibility'}
      <div class="onboarding-actions">
        {#if !accessibilityReady}
          <Button
            state={isPreparingService ? 'loading' : 'idle'}
            disabled={accessibilityStatus === 'Unsupported'}
            on:click={() => prepareService(!hasRequestedAccessibility && accessibilityStatus !== 'Granted')}
          >
            {hasRequestedAccessibility || accessibilityStatus === 'Granted' ? 'Check Again' : 'Open System Settings'}
          </Button>
        {/if}
        {#if accessibilityReady}
          <p class="onboarding-status done" role="status">
            <CheckIcon className="settings-icon" />Harper can read and fix text in the apps you turn on.
          </p>
        {:else if accessibilityStatus === 'Unsupported'}
          <p class="onboarding-status error" role="status">
            Accessibility access isn’t available on this system, so setup can’t continue.
          </p>
        {:else if hasRequestedAccessibility && accessibilityStatus === 'NotGranted'}
          <p class="onboarding-status waiting" role="status">
            <span class="onboarding-spinner" aria-hidden="true"></span>
            <span>
              Waiting for access. In System Settings, open Privacy &amp; Security › Accessibility and
              turn on Harper. This page updates on its own.
            </span>
          </p>
        {:else}
          <p class="onboarding-status" role="status"></p>
        {/if}
        {#if setupError}
          <p class="onboarding-status error" role="alert">{setupError}</p>
        {/if}
      </div>
    {:else if slides[step].id === 'integration'}
      <div class="onboarding-actions">
        <div class="onboarding-app">
          <AppIcon bundleId="com.apple.TextEdit" name="TextEdit" />
          <strong>TextEdit</strong>
          {#if !isTextEditEnabled}
            <Button
              state={isEnablingTextEdit ? 'loading' : 'idle'}
              disabled={!accessibilityReady || isLoadingIntegrations || !!integrationsError}
              on:click={enableTextEditForSetup}
            >
              Turn On
            </Button>
          {/if}
        </div>
        {#if integrationsError}
          <p class="onboarding-status error" role="alert">{integrationsError}</p>
          <Button color="light" disabled={isLoadingIntegrations || isEnablingTextEdit} on:click={loadIntegrations}>
            Try Again
          </Button>
        {:else if integrationReady}
          <p class="onboarding-status done" role="status">
            <CheckIcon className="settings-icon" />Harper will check your writing in TextEdit.
          </p>
        {/if}
      </div>
    {:else if slides[step].id === 'test-drive'}
      <div class="onboarding-actions">
        <Button state={isLaunchingTextEdit ? 'loading' : 'idle'} on:click={launchTextEditForTestDrive}>
          Open TextEdit
        </Button>
        {#if testDriveError}
          <p class="onboarding-status error" role="alert">{testDriveError}</p>
        {/if}
      </div>
    {:else if slides[step].id === 'ready'}
      <div class="onboarding-actions">
        <Button
          state={isCompletingOnboarding ? 'loading' : 'idle'}
          disabled={!accessibilityReady || !integrationReady}
          on:click={completeOnboarding}
        >
          Start Writing
        </Button>
        {#if onboardingError}
          <p class="onboarding-status error" role="alert">{onboardingError}</p>
        {/if}
      </div>
    {/if}
  </SlideDeck>
</div>
