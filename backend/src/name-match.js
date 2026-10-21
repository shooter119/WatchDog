function normalizeForCompare(value) {
  return String(value ?? '').trim().replace(/\s+/g, '').toLowerCase();
}

function levenshteinCodePoints(a, b) {
  const m = a.length;
  const n = b.length;
  if (m === 0) return n;
  if (n === 0) return m;
  let prev = new Array(n + 1);
  let curr = new Array(n + 1);
  for (let j = 0; j <= n; j++) prev[j] = j;
  for (let i = 1; i <= m; i++) {
    curr[0] = i;
    const chA = a[i - 1];
    for (let j = 1; j <= n; j++) {
      const cost = chA === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(
        prev[j] + 1,
        curr[j - 1] + 1,
        prev[j - 1] + cost,
      );
    }
    const tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

function nameSuggestions(input, candidates = [], options = {}) {
  const maxDistance = Number.isFinite(options?.maxDistance)
    ? Math.max(0, Math.trunc(options.maxDistance))
    : 1;
  const limit = Number.isFinite(options?.limit)
    ? Math.max(0, Math.trunc(options.limit))
    : 3;
  if (limit === 0 || !candidates) return [];

  const cleanInput = String(input ?? '').trim();
  const normInput = normalizeForCompare(cleanInput);
  if (!normInput) return [];

  const inputChars = Array.from(normInput);
  const results = [];
  const seen = new Set();

  for (const rawCandidate of candidates) {
    if (results.length >= limit) break;
    const candidate = String(rawCandidate ?? '').trim();
    if (!candidate) continue;
    const normCandidate = normalizeForCompare(candidate);
    if (!normCandidate) continue;
    if (normCandidate === normInput) continue;
    if (seen.has(normCandidate)) continue;

    const candidateChars = Array.from(normCandidate);
    if (Math.abs(inputChars.length - candidateChars.length) > maxDistance) continue;

    const dist = levenshteinCodePoints(inputChars, candidateChars);
    if (dist <= maxDistance) {
      seen.add(normCandidate);
      results.push(candidate);
    }
  }

  return results;
}

module.exports = {
  nameSuggestions,
};
