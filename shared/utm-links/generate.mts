// Regenerates vectors.json from the web tag's own code (SPEC §11.1, §14).
//
//   node shared/utm-links/generate.mts [path/to/onsite-core/src/url.ts]
//
// Node >= 22.18 (type stripping on by default). The default path is the
// sibling checkout ../Mailbiz.Onsite.Tag. `Url` is imported unchanged; the
// body of `evaluate` below is a verbatim copy of `setUtmNavigationContext`
// (onsite-core/src/tracker/tracker-core-invoker.ts), with the 30-day
// StorageFactory replaced by an in-memory cell (expiry is SDK-tested, not
// vector-tested). `expected` is exactly the string web hands to
// `setUtmData` → `context.utm` (`JSON.stringify(finalUtms)`), or null when
// web never calls `setUtmData` (no `utm` key in the envelope).
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const urlTs = resolve(process.argv[2] ?? resolve(here, '../../../Mailbiz.Onsite.Tag/libraries/onsite-core/src/url.ts'));
const { Url } = await import(pathToFileURL(urlTs).href);

const g = globalThis as any;
g.window = { location: { href: 'https://store.com/' } };

type Stored = { utmData?: Record<string, string> } | undefined;
let cell: Stored;
const utmStateManager = {
  get: (fallback: Record<string, any>) => (cell ? JSON.parse(JSON.stringify(cell)) : { ...fallback }),
  set: (data: Record<string, any>) => { cell = JSON.parse(JSON.stringify(data)); },
};
let sent: string | null = null;
const track = (name: string, data: Record<string, string>) => {
  if (name === 'setUtmData') sent = JSON.stringify(data);
};

/** One web page load on `href`; returns the `context.utm` string or null. */
function evaluate(href: string | null): string | null {
  g.window.location.href = href ?? 'https://store.com/';
  sent = null;
  // ---- verbatim: tracker-core-invoker.ts setUtmNavigationContext ----
  const storedUtms = utmStateManager.get({})?.utmData || {};
  const queryParams = Url.getQueryParameters();
  const currentUtms: Record<string, string> = {};

  Object.keys(Url.UtmParameters).forEach((utmName) => {
    const currentUtm = queryParams[utmName];
    if (currentUtm) {
      currentUtms[utmName] = currentUtm;
    }
  });

  const finalUtms = {
    ...storedUtms,
    ...currentUtms,
  };
  if (!(Object.keys(finalUtms).length > 0)) {
    return sent;
  }

  utmStateManager.set({ utmData: finalUtms });
  track('setUtmData', finalUtms);
  // ---- end verbatim ----
  return sent;
}

const MB_CR = 'eyJ0IjoiNzc3NzciLCJ1IjoidXNlci0xMjMiLCJjIjoiY2FydC1hYmMtMDAxIiwiaXRzIjpbWyIyIiwiUDEwMCIsIlNLVS0xMDAtUCJdLFsiMSIsIlAyMDAiLCJTS1UtMjAwLU0iXV19';

// [name, link] — each evaluated as the first page load of a fresh store.
const extract: Array<[string, string]> = [
  // Link shapes the backend emits (MessageBuilder HtmlParseHelper.GetUtmFilledLink: raw, unencoded values).
  ['messagebuilder_flow_cart_recovery', `https://store.com/carrinho?_mb_cr_=${MB_CR}&utm_flow_params=AE-0c3bf2fb-9d1e-4f55-8d0e-3a1c9b7e2f10|3|a1b2c3d4-inst&utm_journey=123&utm_journey_channel=email&utm_source=flowbiz&utm_medium=email&utm_campaign=jornadas|flow|recuperacao-de-carrinho|email-4&utm_journey_type=4`],
  ['messagebuilder_journey_cart_recovery', `https://store.com/carrinho?_mb_cr_=${MB_CR}&utm_journey=16&utm_journey_channel=email&utm_source=flowbiz&utm_medium=email&utm_campaign=jornadas|cart|carrinho-abandonado&utm_journey_type=1`],
  ['messagebuilder_whatsapp_cta', `https://store.com/carrinho?_mb_cr_=${MB_CR}&utm_journey=16&utm_journey_channel=whatsapp&utm_source=flowbiz&utm_medium=whatsapp&utm_campaign=jornadas|cart|carrinho-abandonado&utm_journey_type=1`],
  ['messagebuilder_legacy_tenant_source', `https://store.com/carrinho?utm_journey=7&utm_journey_channel=email&utm_source=MailBiz&utm_medium=Email_I&utm_campaign=jornadas|cart|volte&utm_journey_type=1&_mb_cr_=${MB_CR}`],
  ['recovery_hash_generator_form_encoded', 'https://store.com/carrinho?utm_source=mailbiz&_mb_cr_=eyJ0IjoiNzc3NzciLCJ1IjoidSJ9%3D%3D'],
  ['legacy_newsletter_term_content_dropped', 'https://store.com/?utm_source=flowbiz&utm_medium=email&utm_term=newsletter&utm_content=Subscriber%23123&utm_campaign=Black%20Friday'],
  ['third_party_campaign', 'https://store.com/produto/camisa?utm_source=google&utm_medium=cpc&utm_campaign=spring_sale&gclid=Cj0KCQjw'],
  ['custom_scheme_link', 'myapp://produto/123?utm_source=push&utm_campaign=lancamento'],
  ['universal_link_with_fragment', `https://store.com/carrinho?utm_source=flowbiz&utm_medium=email&_mb_cr_=${MB_CR}#topo`],
  ['allowlist_order_not_query_order', 'https://store.com/?utm_journey_type=1&utm_campaign=c&utm_medium=m&utm_source=s'],
  ['no_host_slash', 'https://store.com?utm_source=a'],
  // No UTMs → web never calls setUtmData.
  ['no_query', 'https://store.com/carrinho'],
  ['empty_query', 'https://store.com/?'],
  ['no_allowlisted_keys', 'https://store.com/?foo=1&bar=2'],
  ['non_allowlisted_utms_dropped', 'https://store.com/?utm_term=t&utm_content=c&gclid=g&utm_flow_params='],
  // Query extent: text between the first and second '?', cut at '/#' then '#'.
  ['hash_route_query_is_read', 'https://store.com/#/cart?utm_source=x'],
  ['query_before_hash_route_wins', 'https://store.com/?a=1#/p?utm_source=x'],
  ['second_question_mark_truncates', 'https://store.com/?utm_source=a?utm_medium=b'],
  ['slash_hash_cut', 'https://store.com/?utm_source=a/#/cart'],
  ['fragment_cut', 'https://store.com/?utm_source=a#utm_medium=b'],
  ['empty_segments_skipped', 'https://store.com/?&&utm_source=a&&'],
  ['semicolon_is_not_a_separator', 'https://store.com/?utm_source=a;utm_medium=b'],
  // Key/value split: split('='), value is pair[1] only; keys raw and case-sensitive.
  ['value_truncated_at_second_equals', 'https://store.com/?utm_campaign=a=b'],
  ['missing_equals_is_undefined', 'https://store.com/?utm_source'],
  ['flow_params_missing_equals', 'https://store.com/?utm_flow_params'],
  ['empty_key_skipped', 'https://store.com/?=utm_source'],
  ['double_equals_empty_value', 'https://store.com/?utm_source==x'],
  ['keys_case_sensitive_and_not_decoded', 'https://store.com/?UTM_SOURCE=a&utm%5Fsource=b'],
  ['last_duplicate_wins', 'https://store.com/?utm_source=a&utm_source=b'],
  ['empty_duplicate_erases', 'https://store.com/?utm_source=a&utm_source=&utm_medium=m'],
  // Value decoding: decodeURIComponent, raw value on failure, '+' untouched.
  ['plus_is_not_space', 'https://store.com/?utm_campaign=a+b%20c'],
  ['malformed_percent_kept_raw', 'https://store.com/?utm_source=%C3&utm_medium=100%'],
  ['invalid_hex_kept_raw', 'https://store.com/?utm_source=%zz'],
  ['surrogate_kept_raw_emoji_decoded', 'myapp://open?utm_medium=%F0%9F%98%80&utm_source=%ED%A0%80'],
  ['overlong_utf8_kept_raw', 'https://store.com/?utm_source=%C0%AF'],
  ['lowercase_hex_decoded', 'https://store.com/?utm_campaign=promo%c3%a7%C3%A3o'],
  ['encoded_ampersand_equals_hash', 'https://store.com/?utm_campaign=a%26b%3Dc%23d'],
  ['whitespace_preserved', 'https://store.com/?utm_source=%20a%20'],
  ['raw_non_ascii', 'https://store.com/?utm_campaign=promoção'],
  ['utf8_boundaries_decoded', 'https://store.com/?utm_source=%F4%8F%BF%BF&utm_medium=%EF%BF%BE&utm_campaign=%EF%BB%BFbom'],
  ['utf8_above_max_kept_raw', 'https://store.com/?utm_source=%F4%90%80%80'],
  ['utf8_overlong_3_and_4_byte_kept_raw', 'https://store.com/?utm_source=%E0%80%80&utm_medium=%F0%80%80%80'],
  ['utf8_truncated_sequence_kept_raw', 'https://store.com/?utm_source=%C2&utm_medium=%E2%9C'],
  ['utf8_bad_continuation_kept_raw', 'https://store.com/?utm_source=%C2%41&utm_medium=%80'],
  ['utf8_lone_continuation_a0_bf_kept_raw', 'https://store.com/?utm_source=%A9&utm_medium=%BF&utm_campaign=%C2%A9'],
  ['utf8_mixed_raw_and_escape_fail_whole_value', 'https://store.com/?utm_campaign=ok%20then%C3'],
  ['combining_mark_after_separators', 'https://store.com/?utm_source≠a&̸utm_medium=b&utm_campaign=c#̸'],
  ['combining_mark_after_question_mark', 'https://store.com/?̸&utm_source=a'],
  // Escaping of the inner JSON (JSON.stringify).
  ['nul_char', 'https://store.com/?utm_source=%00'],
  ['control_chars_lowercase_hex', 'https://store.com/?utm_source=%1F%7F%1B'],
  ['quotes_backslash_newline_tab', 'https://store.com/?utm_campaign=a/b%20%22%C3%A7%22%0A%09%5C&utm_source=x'],
  ['line_separators_raw', 'https://store.com/?utm_campaign=%E2%80%A8%E2%80%A9'],
  // Piped utm_flow_params → utm_step_id | utm_journey_version | utm_journey_instance.
  ['flow_params_encoded_pipes', 'https://store.com/?utm_flow_params=AE-1%7C3%7Cinst-9'],
  ['flow_params_extra_segments_ignored', 'https://store.com/?utm_flow_params=A|B|C|D'],
  ['flow_params_fewer_segments', 'https://store.com/?utm_flow_params=A|1'],
  ['flow_params_undecodable_split_raw', 'https://store.com/?utm_flow_params=A|%E0%A4%A|C'],
  ['flow_params_double_encoded_pipe', 'https://store.com/?utm_flow_params=A%257CB'],
  ['flow_params_after_direct_wins', 'https://store.com/?utm_step_id=X&utm_flow_params=A|B|C'],
  ['direct_after_flow_params_wins', 'https://store.com/?utm_flow_params=A|B|C&utm_step_id=X'],
  ['empty_flow_segment_erases_direct', 'https://store.com/?utm_journey_instance=Z&utm_flow_params=A%7CB%7C'],
  ['flow_params_empty_first_segment', 'https://store.com/?utm_flow_params=|3|I'],
  ['flow_params_empty_value', 'https://store.com/?utm_flow_params='],
];

// [name, steps] — one store, page loads in order; null = a load with no link.
const sequences: Array<[string, Array<string | null>]> = [
  ['merge_per_key_across_links', [
    'https://store.com/',
    'https://store.com/?utm_campaign=c1&utm_source=mailbiz&utm_journey=9&foo=1',
    'https://store.com/?utm_medium=cpc&utm_source=google&utm_campaign=',
    'https://store.com/?utm_flow_params=S|2|I&utm_source',
    'https://store.com/?utm_flow_params=|3|',
    null,
  ]],
  ['stored_keys_keep_first_position', [
    'https://store.com/?utm_campaign=c',
    'https://store.com/?utm_source=s&utm_campaign=d',
    'https://store.com/?utm_medium=m',
  ]],
  ['bare_loads_keep_stored', [
    'https://store.com/?utm_source=flowbiz&utm_journey=16',
    null,
    'https://store.com/produto/1',
    'https://store.com/?utm_source=',
  ]],
  ['empty_store_bare_load_sends_nothing', [
    null,
    'https://store.com/?foo=bar',
  ]],
];

const round = (steps: Array<string | null>) => steps.map((url) => ({ url, expected: evaluate(url) }));

const out = {
  source: 'Mailbiz.Onsite.Tag onsite-core url.ts + tracker-core-invoker.ts setUtmNavigationContext (691c2237)',
  extract: extract.map(([name, url]) => {
    cell = undefined;
    return { name, url, expected: evaluate(url) };
  }),
  sequences: sequences.map(([name, steps]) => {
    cell = undefined;
    return { name, steps: round(steps) };
  }),
  envelope: (() => {
    cell = undefined;
    const utm = evaluate('https://store.com/?utm_campaign=a/b%20%22%C3%A7%22%0A&utm_source=x') as string;
    return { utm, context_canonical: JSON.stringify({ utm }) };
  })(),
};

writeFileSync(resolve(here, 'vectors.json'), JSON.stringify(out, null, 2) + '\n');
console.log(`wrote ${out.extract.length} extract vectors, ${out.sequences.length} sequences`);
