// Port of LocalDayDoAPI.normalizeTags (name part only; DB side effects live elsewhere).

export interface NormalizedTag {
  /** Lowercased key. */
  name: string;
  /** Trimmed label with original casing. */
  label: string;
}

export function normalizeTagLabels(labels: readonly string[]): NormalizedTag[] {
  const out: NormalizedTag[] = [];
  for (const raw of labels) {
    const label = raw.trim().replace(/^#+/, '').replace(/#+$/, '');
    if (label === '') continue;
    const name = label.toLowerCase();
    if (out.some((t) => t.name === name)) continue;
    out.push({ name, label });
  }
  return out;
}

/** Lowercased, de-duplicated tag names in input order. */
export function normalizeTags(labels: readonly string[]): string[] {
  return normalizeTagLabels(labels).map((t) => t.name);
}
