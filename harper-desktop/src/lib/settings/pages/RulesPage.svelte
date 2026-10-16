<!-- Modified in this fork (taehee-pd/harperSwift): macOS-style layout, real rule descriptions,
     switches instead of three-way menus, and confirmations before the bulk actions. -->
<script lang="ts">
import { CloseIcon, IconButton, SearchField, SearchIcon, Select, Toggle } from 'components';
import type { LintConfig, StructuredLintConfig, StructuredLintSetting } from 'harper.js';
import { onMount, tick } from 'svelte';
import { Client } from '$lib/client';
import ConfirmButton from '../components/ConfirmButton.svelte';

type RuleOverride = 'default' | 'on' | 'off';
type RuleItem = { id: string; name: string; desc: string };
type RuleGroup = { id: string; title: string; desc: string; rules: RuleItem[] };
type MatchedRuleGroup = RuleGroup & { matchedRules: RuleItem[] };

let lintConfig: LintConfig | null = null;
let defaultLintConfig: LintConfig | null = null;
let structuredLintConfig: StructuredLintConfig | null = null;
let descriptions: Record<string, string> = {};
let rules: Record<string, RuleOverride> = {};
let rulesSearch = '';
let expandedGroups: Record<string, boolean> = {};
let isLintConfigLoading = true;
let isLintConfigSaving = false;
let lintConfigError = '';

$: rulesQuery = rulesSearch.trim().toLowerCase();
$: ruleGroups = structuredLintConfig
	? ruleGroupsFromStructuredConfig(structuredLintConfig, descriptions)
	: [];
$: displayedRules = ruleGroups.flatMap((group) => group.rules);
// These lookups are rebuilt whenever the state they read changes. Svelte's legacy mode redraws an
// expression only when a variable it names changes, not one a called function reads, so naming a
// rebuilt lookup in the markup keeps the switches and counts current.
$: getRuleValue = (ruleId: string): RuleOverride => rules[ruleId] ?? 'default';
$: isRuleEnabled = (rule: RuleItem): boolean =>
	lintConfig?.[rule.id] ?? defaultLintConfig?.[rule.id] ?? false;
/** What the group menu shows: untouched defaults, all on, all off, or a mix. */
$: getGroupState = (group: RuleGroup): RuleOverride | 'mixed' => {
	if (group.rules.every((rule) => getRuleValue(rule.id) === 'default')) return 'default';
	if (group.rules.every((rule) => isRuleEnabled(rule))) return 'on';
	if (group.rules.every((rule) => !isRuleEnabled(rule))) return 'off';
	return 'mixed';
};
$: enabledRuleCount = displayedRules.filter((rule) => isRuleEnabled(rule)).length;
$: customizedRuleCount = Object.values(rules).filter((value) => value !== 'default').length;
$: filteredRuleGroups = getFilteredRuleGroups(ruleGroups, rulesQuery);
$: matchCount = filteredRuleGroups.reduce((total, group) => total + group.matchedRules.length, 0);

onMount(() => {
	void loadLintConfig();

	const refreshLintConfig = () => {
		if (!isLintConfigSaving) {
			void loadLintConfig();
		}
	};

	window.addEventListener('focus', refreshLintConfig);

	return () => {
		window.removeEventListener('focus', refreshLintConfig);
	};
});

async function loadLintConfig() {
	isLintConfigLoading = true;
	lintConfigError = '';

	try {
		const [
			fetchedLintConfig,
			fetchedDefaultLintConfig,
			fetchedStructuredLintConfig,
			fetchedDescriptions,
		] = await Promise.all([
			Client.getLintConfig(),
			Client.getDefaultLintConfig(),
			Client.getStructuredLintConfig(),
			Client.getLintDescriptions(),
		]);

		lintConfig = fetchedLintConfig;
		defaultLintConfig = fetchedDefaultLintConfig;
		descriptions = fetchedDescriptions;
		structuredLintConfig = fetchedStructuredLintConfig;
		rules = rulesFromLintConfig(fetchedLintConfig, fetchedDefaultLintConfig);
	} catch (error) {
		lintConfigError = `Unable to load rules: ${error}`;
	} finally {
		isLintConfigLoading = false;
	}
}

function rulesFromLintConfig(
	config: LintConfig,
	defaultConfig: LintConfig,
): Record<string, RuleOverride> {
	return Object.fromEntries(
		Object.entries(config).map(([ruleId, value]) => [
			ruleId,
			value === defaultConfig[ruleId] ? 'default' : lintValueToRuleOverride(value),
		]),
	);
}

function lintValueToRuleOverride(value: boolean | null | undefined): RuleOverride {
	if (value === true) return 'on';
	if (value === false) return 'off';
	return 'default';
}

function ruleOverrideToLintValue(ruleId: string, value: RuleOverride): boolean {
	if (value === 'on') return true;
	if (value === 'off') return false;

	return defaultLintConfig?.[ruleId] ?? false;
}

function ruleLabelFromKey(key: string) {
	return key
		.replace(/([a-z0-9])([A-Z])/g, '$1 $2')
		.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
		.trim();
}

/** Rule descriptions are Markdown; the list shows them as plain text. */
function plainDescription(markdown: string | undefined) {
	return (markdown ?? '').replace(/`|\*\*/g, '').trim();
}

function ruleGroupsFromStructuredConfig(
	config: StructuredLintConfig,
	descriptions: Record<string, string>,
): RuleGroup[] {
	const groups: RuleGroup[] = [];
	const looseRules: RuleItem[] = [];

	for (const setting of config.settings) {
		if ('Group' in setting) {
			groups.push(...groupsFromSetting(setting.Group, descriptions));
		} else {
			looseRules.push(...rulesFromSetting(setting, descriptions));
		}
	}

	if (looseRules.length > 0) {
		groups.push({
			id: 'ungrouped-rules',
			title: 'Other Rules',
			desc: 'Rules that are not part of a category.',
			rules: looseRules,
		});
	}

	return groups;
}

function groupsFromSetting(
	group: Extract<StructuredLintSetting, { Group: unknown }>['Group'],
	descriptions: Record<string, string>,
): RuleGroup[] {
	const groups: RuleGroup[] = [];
	const rules: RuleItem[] = [];

	for (const setting of group.child.settings) {
		if ('Group' in setting) {
			groups.push(...groupsFromSetting(setting.Group, descriptions));
		} else {
			rules.push(...rulesFromSetting(setting, descriptions));
		}
	}

	if (rules.length > 0) {
		groups.unshift({
			id: `${groups.length}-${group.label}`,
			title: group.label,
			desc: group.description,
			rules,
		});
	}

	return groups;
}

function rulesFromSetting(
	setting: StructuredLintSetting,
	descriptions: Record<string, string>,
): RuleItem[] {
	if ('Bool' in setting) {
		return [
			{
				id: setting.Bool.name,
				name: setting.Bool.label ?? ruleLabelFromKey(setting.Bool.name),
				desc: plainDescription(descriptions[setting.Bool.name]),
			},
		];
	}

	if ('OneOfMany' in setting) {
		return setting.OneOfMany.names.map((name, index) => ({
			id: name,
			name: setting.OneOfMany.labels?.[index] ?? ruleLabelFromKey(name),
			desc: plainDescription(descriptions[name]),
		}));
	}

	return [];
}

async function saveLintConfig(nextLintConfig: LintConfig, nextRules: Record<string, RuleOverride>) {
	const previousLintConfig = lintConfig;
	const previousRules = rules;

	lintConfig = nextLintConfig;
	rules = nextRules;
	isLintConfigSaving = true;
	lintConfigError = '';

	try {
		await Client.setLintConfig(nextLintConfig);
	} catch (error) {
		lintConfig = previousLintConfig;
		rules = previousRules;
		lintConfigError = `Unable to save lint config: ${error}`;
	} finally {
		isLintConfigSaving = false;
	}
}

function setLintConfigRuleValue(config: LintConfig, ruleId: string, value: RuleOverride) {
	config[ruleId] = ruleOverrideToLintValue(ruleId, value);
}

function getFilteredRuleGroups(ruleGroups: RuleGroup[], query: string): MatchedRuleGroup[] {
	if (!query) {
		return ruleGroups.map((group) => ({ ...group, matchedRules: group.rules }));
	}

	return ruleGroups
		.map((group) => {
			const groupMatches =
				group.title.toLowerCase().includes(query) || group.desc.toLowerCase().includes(query);
			const matchedRules = group.rules.filter(
				(rule) =>
					rule.name.toLowerCase().includes(query) || rule.desc.toLowerCase().includes(query),
			);

			if (groupMatches) {
				return { ...group, matchedRules: group.rules };
			}

			if (matchedRules.length > 0) {
				return { ...group, matchedRules };
			}

			return null;
		})
		.filter((group): group is MatchedRuleGroup => group !== null);
}

function allKnownRuleIds() {
	return new Set([
		...Object.keys(defaultLintConfig ?? {}),
		...Object.keys(lintConfig ?? {}),
		...displayedRules.map((rule) => rule.id),
	]);
}

async function setRuleOverride(ruleId: string, value: RuleOverride) {
	const nextRules = { ...rules };

	nextRules[ruleId] = value;

	if (!lintConfig) {
		rules = nextRules;
		return;
	}

	const nextLintConfig = { ...lintConfig };
	setLintConfigRuleValue(nextLintConfig, ruleId, value);
	await saveLintConfig(nextLintConfig, nextRules);
}

/** A switch shows whether a rule is on. Matching the default again clears the override. */
async function setRuleEnabled(rule: RuleItem, enabled: boolean) {
	const enabledByDefault = defaultLintConfig?.[rule.id] ?? false;
	await setRuleOverride(rule.id, enabled === enabledByDefault ? 'default' : enabled ? 'on' : 'off');
}

async function setGroupOverride(group: RuleGroup, value: RuleOverride) {
	const nextRules = { ...rules };
	const nextLintConfig = lintConfig ? { ...lintConfig } : null;

	for (const rule of group.rules) {
		nextRules[rule.id] = value;

		if (nextLintConfig) {
			setLintConfigRuleValue(nextLintConfig, rule.id, value);
		}
	}

	if (!nextLintConfig) {
		rules = nextRules;
		return;
	}

	// A rule turned on that is on by default is not a change, so derive the overrides from the
	// saved values.
	await saveLintConfig(
		nextLintConfig,
		rulesFromLintConfig(nextLintConfig, defaultLintConfig ?? {}),
	);
}

/** The group menu is an action; afterwards it shows the group's resulting state, which may be
 * "Defaults" even after "All On". */
async function applyGroupMenu(group: RuleGroup, select: HTMLSelectElement) {
	await setGroupOverride(group, select.value as RuleOverride);
	await tick();
	select.value = getGroupState(group);
}

async function resetRules() {
	if (!lintConfig) {
		rules = {};
		return;
	}

	const nextLintConfig = { ...lintConfig };

	// Every known rule, like Turn All Off, so rules the list does not show are restored too.
	for (const ruleId of allKnownRuleIds()) {
		nextLintConfig[ruleId] = defaultLintConfig?.[ruleId] ?? false;
	}

	await saveLintConfig(
		nextLintConfig,
		rulesFromLintConfig(nextLintConfig, defaultLintConfig ?? {}),
	);
}

async function disableRules() {
	const nextLintConfig = { ...(lintConfig ?? defaultLintConfig ?? {}) };

	for (const ruleId of allKnownRuleIds()) {
		nextLintConfig[ruleId] = false;
	}

	const nextRules = rulesFromLintConfig(nextLintConfig, defaultLintConfig ?? {});

	if (!lintConfig) {
		rules = nextRules;
		return;
	}

	await saveLintConfig(nextLintConfig, nextRules);
}

function toggleGroup(groupId: string) {
	if (rulesQuery) return;
	expandedGroups = { ...expandedGroups, [groupId]: !expandedGroups[groupId] };
}
</script>

<section>
  <header class="page-header">
    <h1>Rules</h1>
    <p class="page-lede">
      {#if structuredLintConfig}
        {enabledRuleCount} of {displayedRules.length} rules are on{customizedRuleCount > 0
          ? `, ${customizedRuleCount} changed from the defaults`
          : ''}.
      {:else}
        Choose what Harper checks.
      {/if}
    </p>
  </header>

  <div class="sticky-tools">
    <SearchField class="search-field" placeholder="Search rules" aria-label="Search rules" bind:value={rulesSearch}>
      <SearchIcon slot="leading" className="control-icon" />
      <svelte:fragment slot="trailing">
        {#if rulesSearch}
          <IconButton aria-label="Clear search" on:click={() => (rulesSearch = "")}>
            <CloseIcon className="control-icon" />
          </IconButton>
        {/if}
      </svelte:fragment>
    </SearchField>
    <ConfirmButton
      label="Restore Defaults…"
      question="Undo all your rule changes?"
      confirmLabel="Restore"
      disabled={isLintConfigLoading || isLintConfigSaving || customizedRuleCount === 0}
      onConfirm={resetRules}
    />
    <ConfirmButton
      label="Turn All Off…"
      question="Turn off every rule?"
      confirmLabel="Turn All Off"
      disabled={isLintConfigLoading || isLintConfigSaving || enabledRuleCount === 0}
      onConfirm={disableRules}
    />
  </div>

  {#if lintConfigError}
    <p class="form-error" role="alert">{lintConfigError}</p>
  {/if}

  {#if rulesQuery}
    <p class="form-status" role="status">
      {#if matchCount === 0}
        No rules match “{rulesSearch.trim()}”.
      {:else}
        {matchCount} {matchCount === 1 ? 'rule matches' : 'rules match'} “{rulesSearch.trim()}”.
      {/if}
    </p>
  {/if}

  {#if !structuredLintConfig && isLintConfigLoading}
    <div class="empty" role="status">Loading rules…</div>
  {/if}

  <div class="rule-groups">
    {#each filteredRuleGroups as group (group.id)}
      {@const expanded = rulesQuery || expandedGroups[group.id]}
      {@const groupState = getGroupState(group)}
      {@const groupEnabledCount = group.rules.filter((rule) => isRuleEnabled(rule)).length}
      <article class="form-group">
        <div class="rule-group-head">
          <button
            class="disclosure"
            type="button"
            disabled={Boolean(rulesQuery)}
            aria-expanded={Boolean(expanded)}
            aria-controls={`rules-${group.id}`}
            on:click={() => toggleGroup(group.id)}
          >
            <svg class:expanded class="chevron" viewBox="0 0 16 16" aria-hidden="true">
              <path
                fill-rule="evenodd"
                d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z"
                clip-rule="evenodd"
              />
            </svg>
            <span class="grow">
              <strong>{group.title}</strong>
              <span class="count">{groupEnabledCount} of {group.rules.length} on</span>
              <p class="form-row-detail">{group.desc}</p>
            </span>
          </button>
          <Select
            unstyled
            class="select compact"
            aria-label={`All rules in ${group.title}`}
            disabled={isLintConfigLoading || isLintConfigSaving}
            value={groupState === "mixed" ? "mixed" : groupState}
            on:change={(event) => applyGroupMenu(group, event.detail.currentTarget as HTMLSelectElement)}
          >
            {#if groupState === "mixed"}
              <option value="mixed" disabled>Mixed</option>
            {/if}
            <option value="default">Defaults</option>
            <option value="on">All On</option>
            <option value="off">All Off</option>
          </Select>
        </div>

        {#if expanded}
          <div class="rule-list" id={`rules-${group.id}`}>
            {#each group.matchedRules as rule (rule.id)}
              {@const changed = getRuleValue(rule.id) !== "default"}
              <div class="form-row">
                <div class="form-row-text">
                  <span class="rule-name" id={`rule-${rule.id}`}>{rule.name}</span>
                  {#if changed}
                    <span class="changed-dot" title="Changed from the default"></span>
                    <span class="sr-only">(changed from the default)</span>
                  {/if}
                  {#if rule.desc}
                    <p class="form-row-detail rule-description" title={rule.desc}>{rule.desc}</p>
                  {/if}
                </div>
                <Toggle
                  appearance="settings"
                  checked={isRuleEnabled(rule)}
                  disabled={isLintConfigLoading || isLintConfigSaving}
                  aria-labelledby={`rule-${rule.id}`}
                  on:click={() => setRuleEnabled(rule, !isRuleEnabled(rule))}
                />
              </div>
            {/each}
          </div>
        {/if}
      </article>
    {/each}
  </div>
</section>
