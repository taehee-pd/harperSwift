<!-- Added in this fork (taehee-pd/harperSwift): a button for actions that cannot be undone. The
     first click asks in place; the action runs only after a second, explicit click. -->
<script lang="ts">
import { tick } from 'svelte';

/** The button label, such as "Remove All…". */
export let label: string;
/** The question shown while asking, such as "Remove all 12 words?". */
export let question: string;
/** The label of the button that runs the action, such as "Remove All". */
export let confirmLabel: string;
export let disabled = false;
export let onConfirm: () => void | Promise<void>;

let isAsking = false;
let trigger: HTMLButtonElement;
let cancelButton: HTMLButtonElement;

// Stop asking if the action stops applying meanwhile (say, the last change was undone by hand).
$: if (disabled && isAsking) {
	isAsking = false;
}

async function ask() {
	isAsking = true;
	await tick();
	// Cancel takes focus, so pressing Return or Space by habit does not run the action.
	cancelButton?.focus();
}

async function cancel() {
	isAsking = false;
	await tick();
	trigger?.focus();
}

async function confirm() {
	isAsking = false;
	await onConfirm();
	// Keep keyboard focus here rather than losing it with the removed buttons. Focus does nothing
	// when the action left the button disabled.
	await tick();
	trigger?.focus();
}
</script>

{#if isAsking}
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <span
    class="confirm"
    role="group"
    aria-label={question}
    on:keydown={(event) => event.key === 'Escape' && cancel()}
  >
    <span class="confirm-question">{question}</span>
    <button bind:this={cancelButton} class="button" type="button" on:click={cancel}>Cancel</button>
    <button class="button danger-fill" type="button" {disabled} on:click={confirm}>{confirmLabel}</button>
  </span>
{:else}
  <button bind:this={trigger} class="button" type="button" {disabled} on:click={ask}>{label}</button>
{/if}
