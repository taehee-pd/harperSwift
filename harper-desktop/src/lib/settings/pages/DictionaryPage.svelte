<!-- Modified in this fork (taehee-pd/harperSwift): macOS-style layout, inline duplicate check,
     empty states, and a confirmation before removing every word. -->
<script lang="ts">
import { CloseIcon, IconButton, Input, SearchField, SearchIcon } from 'components';
import { onMount } from 'svelte';
import { Client } from '$lib/client';
import ConfirmButton from '../components/ConfirmButton.svelte';

let dictionary: string[] = [];
let newDictionaryWord = '';
let dictionarySearch = '';
let isDictionaryLoading = true;
let isDictionarySaving = false;
let dictionaryError = '';
let importInput: HTMLInputElement;

$: filteredWords = dictionary.filter((word: string) =>
	word.toLowerCase().includes(dictionarySearch.trim().toLowerCase()),
);

$: isNewWordDuplicate = dictionary.includes(newDictionaryWord.trim());
$: canAddWord =
	newDictionaryWord.trim() !== '' &&
	!isNewWordDuplicate &&
	!isDictionaryLoading &&
	!isDictionarySaving;

onMount(() => {
	void loadDictionary();

	const refreshDictionary = () => {
		if (!isDictionarySaving) {
			void loadDictionary();
		}
	};

	window.addEventListener('focus', refreshDictionary);

	return () => {
		window.removeEventListener('focus', refreshDictionary);
	};
});

async function loadDictionary() {
	isDictionaryLoading = true;
	dictionaryError = '';

	try {
		dictionary = await Client.getDictionary();
	} catch (error) {
		dictionaryError = `Unable to load dictionary: ${error}`;
	} finally {
		isDictionaryLoading = false;
	}
}

async function saveDictionary(nextDictionary: string[]) {
	const previousDictionary = dictionary;

	dictionary = nextDictionary;
	isDictionarySaving = true;
	dictionaryError = '';

	try {
		await Client.setDictionary(nextDictionary);
	} catch (error) {
		dictionary = previousDictionary;
		dictionaryError = `Unable to save dictionary: ${error}`;
	} finally {
		isDictionarySaving = false;
	}
}

function sortDictionary(words: string[]) {
	return [...words].sort((a, b) => a.localeCompare(b));
}

function parseDictionaryText(text: string) {
	return text
		.split(/\r?\n/)
		.map((word) => word.trim())
		.filter(Boolean);
}

function mergeDictionaryWords(words: string[]) {
	return sortDictionary([...new Set([...dictionary, ...words])]);
}

async function addDictionaryWord(inputWord: string) {
	const word = inputWord.trim();

	if (!word || dictionary.includes(word)) {
		return;
	}

	const previousDictionary = dictionary;
	dictionary = sortDictionary([...dictionary, word]);
	isDictionarySaving = true;
	dictionaryError = '';

	try {
		await Client.addToDictionary(word);
		dictionary = await Client.getDictionary();
	} catch (error) {
		dictionary = previousDictionary;
		dictionaryError = `Unable to add dictionary word: ${error}`;
	} finally {
		isDictionarySaving = false;
	}
}

async function removeDictionaryWord(word: string) {
	await saveDictionary(dictionary.filter((item) => item !== word));
}

async function clearDictionary() {
	await saveDictionary([]);
}

async function importDictionary(event: Event) {
	const input = event.currentTarget as HTMLInputElement;
	const file = input.files?.[0];

	if (!file) {
		return;
	}

	try {
		const importedWords = parseDictionaryText(await file.text());
		await saveDictionary(mergeDictionaryWords(importedWords));
	} catch (error) {
		dictionaryError = `Unable to import dictionary: ${error}`;
	} finally {
		input.value = '';
	}
}

function exportDictionary() {
	try {
		const blob = new Blob([`${dictionary.join('\n')}\n`], { type: 'text/plain;charset=utf-8' });
		const url = URL.createObjectURL(blob);
		const link = document.createElement('a');

		link.href = url;
		link.download = 'harper-dictionary.txt';
		link.click();
		URL.revokeObjectURL(url);
	} catch (error) {
		dictionaryError = `Unable to export dictionary: ${error}`;
	}
}

async function submitDictionaryWord() {
	if (!canAddWord) {
		return;
	}

	const word = newDictionaryWord;
	newDictionaryWord = '';
	await addDictionaryWord(word);

	// Give the word back if it could not be added and nothing new was typed.
	if (dictionaryError && newDictionaryWord === '') {
		newDictionaryWord = word;
	}
}
</script>

<section>
  <header class="page-header">
    <h1>Dictionary</h1>
    <p class="page-lede">
      Harper never flags the words in your dictionary. Add names, places, and terms you use often.
    </p>
  </header>

  <div class="form-section">
    <form class="add-word" on:submit|preventDefault={submitDictionaryWord}>
      <Input
        unstyled
        class="text-field"
        type="text"
        placeholder="New word"
        aria-label="New word"
        autocomplete="off"
        spellcheck="false"
        disabled={isDictionaryLoading}
        bind:value={newDictionaryWord}
      />
      <button class="button primary" type="submit" disabled={!canAddWord}>Add</button>
    </form>
    <p class="field-hint" aria-live="polite">
      {isNewWordDuplicate ? `“${newDictionaryWord.trim()}” is already in your dictionary.` : ''}
    </p>

    <div class="form-group">
      <div class="list-toolbar">
        <SearchField class="search-field" placeholder="Search" aria-label="Search your dictionary" bind:value={dictionarySearch}>
          <SearchIcon slot="leading" className="control-icon" />
        </SearchField>
        <span class="list-count">
          {dictionarySearch.trim()
            ? `${filteredWords.length} of ${dictionary.length}`
            : `${dictionary.length} ${dictionary.length === 1 ? 'word' : 'words'}`}
        </span>
      </div>

      <div class="list-scroll">
        {#if isDictionaryLoading && dictionary.length === 0}
          <div class="empty" role="status">Loading…</div>
        {:else if dictionary.length === 0}
          <div class="empty">
            <strong>No words yet</strong>
            Words you add here, or with Add to Dictionary in a suggestion, appear in this list.
          </div>
        {:else if filteredWords.length === 0}
          <div class="empty">No words match “{dictionarySearch.trim()}”.</div>
        {:else}
          {#each filteredWords as word (word)}
            <div class="list-row">
              <span class="grow">{word}</span>
              <IconButton
                danger
                disabled={isDictionaryLoading || isDictionarySaving}
                aria-label={`Remove ${word}`}
                title="Remove"
                on:click={() => removeDictionaryWord(word)}
              >
                <CloseIcon className="control-icon" />
              </IconButton>
            </div>
          {/each}
        {/if}
      </div>
    </div>
    {#if dictionaryError}
      <p class="form-error" role="alert">{dictionaryError}</p>
    {/if}

    <div class="actions-row">
      <input
        bind:this={importInput}
        type="file"
        accept=".txt,.dic,text/plain"
        hidden
        on:change={importDictionary}
      />
      <button
        class="button"
        type="button"
        disabled={isDictionaryLoading || isDictionarySaving}
        on:click={() => importInput.click()}
      >Import…</button>
      <button
        class="button"
        type="button"
        disabled={isDictionaryLoading || dictionary.length === 0}
        on:click={exportDictionary}
      >Export…</button>
      <span class="spacer"></span>
      {#if dictionary.length > 0}
        <ConfirmButton
          label="Remove All…"
          question={`Remove all ${dictionary.length} ${dictionary.length === 1 ? 'word' : 'words'}?`}
          confirmLabel="Remove All"
          disabled={isDictionaryLoading || isDictionarySaving}
          onConfirm={clearDictionary}
        />
      {/if}
    </div>
  </div>
</section>
