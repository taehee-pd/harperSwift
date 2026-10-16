<!-- Modified in this fork (taehee-pd/harperSwift): a macOS-style sheet. Clicking an app adds it
     and closes the sheet in one step, apps already in the list are marked, a typed bundle ID can
     be added directly, the search field takes focus, and Escape closes. The sheet keeps its own
     search text and a snapshot of the list, so its contents hold still while it fades out. -->
<script lang="ts">
import { SearchIcon } from 'components';
import { onMount } from 'svelte';
import { fade } from 'svelte/transition';
import { type AppSearchResult, Client } from '$lib/client';
import AppIcon from './AppIcon.svelte';

export let existingBundleIds: string[];
export let close: () => void;
export let add: (bundleId: string) => void;

const addedAtOpen = new Set(existingBundleIds);

const reduceMotion =
	typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

let searchResults: AppSearchResult[] = [];
let isSearching = false;
let hasSearched = false;
let debounceTimeout: number | null = null;
let searchRequestId = 0;
let searchInput: HTMLInputElement;
let searchText = '';
let isChosen = false;

$: query = searchText.trim();
/** A typed bundle ID ("com.example.App") that search did not find can still be added. */
$: canAddTypedBundleId =
	/^[\w-]+(\.[\w-]+)+$/.test(query) &&
	!isAdded(query) &&
	!searchResults.some((result) => result.bundle_id === query);

onMount(() => {
	searchInput?.focus();
	void performSearch('');
	return () => {
		if (debounceTimeout) clearTimeout(debounceTimeout);
	};
});

async function performSearch(nextQuery: string) {
	const requestId = ++searchRequestId;

	isSearching = true;
	try {
		const results = await Client.searchApps(nextQuery);

		if (requestId === searchRequestId && nextQuery === searchText) {
			searchResults = results;
		}
	} catch (searchError) {
		console.error('Search failed:', searchError);

		if (requestId === searchRequestId) {
			searchResults = [];
		}
	} finally {
		if (requestId === searchRequestId) {
			isSearching = false;
			hasSearched = true;
		}
	}
}

function handleInput() {
	if (debounceTimeout) {
		clearTimeout(debounceTimeout);
	}

	debounceTimeout = window.setTimeout(() => {
		void performSearch(searchText);
	}, 200);
}

function isAdded(id: string) {
	return addedAtOpen.has(id);
}

/** Adds the app and closes at once; the list behind shows the new app right away. */
function choose(id: string) {
	if (isChosen || isAdded(id)) return;
	isChosen = true;
	close();
	add(id);
}

/** Return adds the first app that is not in the list yet, or the typed bundle ID. */
function submit() {
	const first = searchResults.find((result) => !isAdded(result.bundle_id));
	if (first) {
		choose(first.bundle_id);
	} else if (canAddTypedBundleId) {
		choose(query);
	}
}

/** The sheet drops in slightly from the top of the window, as macOS sheets do. */
function sheet(_node: Element) {
	return {
		duration: reduceMotion ? 120 : 220,
		css: (t: number) => {
			const eased = 1 - (1 - t) ** 3;
			return reduceMotion
				? `opacity: ${t}`
				: `opacity: ${t}; transform: translateY(${(1 - eased) * -10}px) scale(${0.98 + eased * 0.02})`;
		},
	};
}
</script>

<svelte:window on:keydown={(event) => event.key === 'Escape' && close()} />

<!-- The backdrop closes on click; Escape and the Cancel button do the same for keyboard users. -->
<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div
  class="sheet-backdrop"
  transition:fade|global={{ duration: reduceMotion ? 120 : 160 }}
  on:click|self={close}
>
  <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="add-app-title" transition:sheet|global>
    <div class="sheet-head">
      <h2 id="add-app-title">Add an App</h2>
      <p>Search by name, or type a bundle ID such as com.apple.TextEdit.</p>
      <div class="search-field">
        <SearchIcon className="control-icon" />
        <input
          bind:this={searchInput}
          type="text"
          placeholder="Search apps"
          aria-label="Search apps"
          autocomplete="off"
          spellcheck="false"
          bind:value={searchText}
          on:input={handleInput}
          on:keydown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault();
              submit();
            }
          }}
        />
      </div>
    </div>

    <div class="sheet-list" aria-busy={isSearching}>
      {#if canAddTypedBundleId}
        <button class="sheet-row" type="button" on:click={() => choose(query)}>
          <AppIcon bundleId={query} name={query} />
          <span class="grow">
            <span class="app-name">Add “{query}”</span>
            <span class="app-bundle">Bundle ID</span>
          </span>
        </button>
      {/if}

      {#each searchResults as result (result.bundle_id)}
        {@const added = isAdded(result.bundle_id)}
        <button
          class="sheet-row"
          type="button"
          disabled={added}
          on:click={() => choose(result.bundle_id)}
        >
          <AppIcon bundleId={result.bundle_id} name={result.name} />
          <span class="grow">
            <span class="app-name">{result.name}</span>
            <span class="app-bundle">{result.bundle_id}</span>
          </span>
          {#if added}<span class="sheet-row-hint">Added</span>{/if}
        </button>
      {:else}
        {#if hasSearched && !isSearching && !canAddTypedBundleId}
          <div class="empty">
            {#if query && isAdded(query)}
              That app is already in your list.
            {:else if query}
              No apps match “{query}”.
            {:else}
              No apps found.
            {/if}
          </div>
        {/if}
      {/each}
    </div>

    <div class="sheet-foot">
      <span class="spacer"></span>
      <button class="button" type="button" on:click={close}>Cancel</button>
    </div>
  </div>
</div>
