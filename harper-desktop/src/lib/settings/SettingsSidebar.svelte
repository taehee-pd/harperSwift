<!-- Modified in this fork (taehee-pd/harperSwift): macOS sidebar styling, arrow-key navigation,
     and aria-current on the selected section. -->
<script lang="ts">
import {
	BookIcon,
	ChecklistIcon,
	GearIcon,
	GridIcon,
	InfoIcon,
	KeyIcon,
	PackageIcon,
	QuillIcon,
} from 'components';
import { FOOTER_NAV_ITEMS, MAIN_NAV_ITEMS, type SectionId } from './settings-data';

const SECTION_ICONS: Record<SectionId, typeof GearIcon> = {
	general: GearIcon,
	writing: QuillIcon,
	dictionary: BookIcon,
	shortcuts: KeyIcon,
	rules: ChecklistIcon,
	weirpacks: PackageIcon,
	integrations: GridIcon,
	about: InfoIcon,
};

const ALL_ITEMS = [...MAIN_NAV_ITEMS, ...FOOTER_NAV_ITEMS];

export let active: SectionId;

let nav: HTMLElement;

/** Up and down move between sections, the way a macOS source list does. */
function handleKeydown(event: KeyboardEvent) {
	if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
	event.preventDefault();

	const index = ALL_ITEMS.findIndex((item) => item.id === active);
	const step = event.key === 'ArrowDown' ? 1 : -1;
	const next = ALL_ITEMS[(index + step + ALL_ITEMS.length) % ALL_ITEMS.length];
	active = next.id;
	nav.querySelector<HTMLButtonElement>(`[data-section="${next.id}"]`)?.focus();
}
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<nav bind:this={nav} class="sidebar" aria-label="Settings sections" on:keydown={handleKeydown}>
  {#each [MAIN_NAV_ITEMS, FOOTER_NAV_ITEMS] as items, groupIndex}
    {#if groupIndex > 0}<div class="separator"></div>{/if}
    <div class="group">
      {#each items as item}
        <button
          type="button"
          class:selected={active === item.id}
          class="nav-item"
          data-section={item.id}
          aria-current={active === item.id ? 'page' : undefined}
          on:click={() => (active = item.id)}
        >
          <span class="tile" style={`--tile-gradient: ${item.gradient}`}>
            <svelte:component this={SECTION_ICONS[item.id]} className="settings-icon" />
          </span>
          <span class="label">{item.label}</span>
        </button>
      {/each}
    </div>
  {/each}
</nav>

<style>
  .sidebar {
    width: 200px;
    flex: 0 0 200px;
    display: flex;
    flex-direction: column;
    border-right: 0.5px solid var(--settings-line-strong);
    background: var(--settings-bg-sidebar);
    padding: 14px 10px 12px;
  }

  .group {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .separator {
    height: 0.5px;
    margin: 10px 8px;
    background: var(--settings-line-strong);
  }

  .nav-item {
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    gap: 8px;
    border: 0;
    border-radius: 6px;
    padding: 0 8px 0 6px;
    background: transparent;
    color: var(--settings-ink);
    text-align: left;
  }

  .nav-item:active:not(.selected) {
    background: var(--settings-press);
  }

  .nav-item.selected {
    background: var(--settings-accent);
    color: #fff;
  }

  .tile {
    width: 20px;
    height: 20px;
    flex: 0 0 20px;
    display: grid;
    place-items: center;
    border-radius: 5px;
    background: var(--tile-gradient);
    color: #fff;
    box-shadow:
      0 0.5px 1px rgba(0, 0, 0, 0.12),
      inset 0 0.5px 0 rgba(255, 255, 255, 0.3);
  }

  .tile :global(.settings-icon) {
    transform: scale(0.82);
  }

  .label {
    min-width: 0;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
