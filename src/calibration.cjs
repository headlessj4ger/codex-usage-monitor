'use strict';

const DAY = 86400000;
const LOOKBACK = 28 * DAY;
const RESET_JITTER = 120;
const UNKNOWN = 'unknown';
const MIN_INTERVAL_PP = 3;
const MAX_INTERVAL_PP = 15;
const MIN_OBSERVATIONS = 18;
const MIN_TRAIN = 12;
const MIN_HOLDOUT = 5;
const MIN_CURRENT = 3;
const MIN_EXPOSURE_PP = 0.5;
const RANK_TOLERANCE = 0.05;
const RATE_FLOOR = 1e-8;

const groupKey = r => JSON.stringify([r.model || UNKNOWN, r.effort || UNKNOWN, r.tier || UNKNOWN]);
const dimensions = key => {
  const [model, effort, tier] = JSON.parse(key);
  return { key, model, effort, tier };
};
const sum = values => values.reduce((total, value) => total + value, 0);
const dot = (a, b) => a.reduce((total, value, i) => total + value * b[i], 0);
const features = r => [r.input - r.cached, r.cached, r.output].map(n => n / 1e6);
const known = value => typeof value === 'string' && value !== '' && value !== UNKNOWN;
const hasContext = row => row.kind === 'response' && [row.model, row.effort, row.tier].every(known);
const validUsage = row => [row.input, row.cached, row.output, row.total].every(n => Number.isSafeInteger(n) && n >= 0)
  && row.cached <= row.input && row.input + row.output === row.total;
const sameCycle = (a, b) => Math.abs(a - b) <= RESET_JITTER;

function upperBound(rows, at) {
  let low = 0, high = rows.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (rows[middle].at_ms <= at) low = middle + 1;
    else high = middle;
  }
  return low;
}

function validSnapshot(q) {
  return Number.isFinite(q.at_ms) && Number.isFinite(q.reset_at) && Number.isFinite(q.used_percent)
    && q.used_percent >= 0 && q.used_percent <= 100
    && q.reset_at * 1000 > q.at_ms && q.reset_at * 1000 - 7 * DAY <= q.at_ms + RESET_JITTER * 1000;
}

function buildObservations(usage, quotas, latest, options = {}) {
  const skipped = { gap: 0, backwards: 0, unknown: 0, missing: 0, empty: 0, jump: 0, invalid: 0, conflict: 0, plan_change: 0, malformed_usage: 0, unlisted_model: 0 };
  const from = latest.at_ms - LOOKBACK;
  const rows = usage.filter(r => r.at_ms <= latest.at_ms && r.at_ms >= from).sort((a, b) => a.at_ms - b.at_ms);
  const snapshots = quotas.filter(q => q.scope === latest.scope && q.limit_id === 'codex' && q.window_minutes === 10080
    && q.at_ms <= latest.at_ms && q.at_ms >= from).sort((a, b) => a.at_ms - b.at_ms || a.reset_at - b.reset_at);
  const missing = options.missingRanges || [];
  const minimumChange = options.minimumChange ?? MIN_INTERVAL_PP;
  const observations = [];
  let anchor = null, previous = null, cycleReset = null, highWater = 0;
  let plan = null, planCutoff = 0, hasPlanChange = false;
  let latestUncertain = false;

  for (let i = 0; i < snapshots.length;) {
    const q = snapshots[i++];
    let conflicting = false, conflictingPlan = false;
    while (i < snapshots.length && snapshots[i].at_ms === q.at_ms) {
      const duplicate = snapshots[i++];
      if (duplicate.plan !== q.plan) conflictingPlan = true;
      if (duplicate.used_percent !== q.used_percent || !sameCycle(duplicate.reset_at, q.reset_at)) conflicting = true;
    }
    if (conflicting || conflictingPlan) {
      skipped.conflict++;
      anchor = previous = null;
      if (conflictingPlan) {
        hasPlanChange = true;
        planCutoff = 0;
      }
      if (q.at_ms === latest.at_ms) latestUncertain = true;
      continue;
    }
    if (!validSnapshot(q)) {
      skipped.invalid++;
      anchor = previous = null;
      if (q.at_ms === latest.at_ms) latestUncertain = true;
      continue;
    }
    if (plan !== q.plan) {
      if (plan !== null) {
        skipped.plan_change++;
        hasPlanChange = true;
      }
      plan = q.plan;
      cycleReset = null;
      anchor = previous = null;
      planCutoff = hasPlanChange ? q.at_ms : 0;
    } else if (hasPlanChange && !planCutoff) {
      planCutoff = q.at_ms;
    }
    if (plan !== latest.plan) continue;

    if (cycleReset !== null && q.reset_at < cycleReset - RESET_JITTER) {
      // A late snapshot from an older cycle cannot reopen that cycle.
      skipped.backwards++;
      if (q.at_ms === latest.at_ms) latestUncertain = true;
      continue;
    }
    if (cycleReset === null || !sameCycle(cycleReset, q.reset_at)) {
      cycleReset = q.reset_at;
      highWater = 0;
      anchor = previous = null;
    }
    if (q.used_percent < highWater) {
      // Wait for the high water mark before starting another interval.
      skipped.backwards++;
      anchor = previous = null;
      if (q.at_ms === latest.at_ms) latestUncertain = true;
      continue;
    }
    highWater = q.used_percent;
    if (q.used_percent === 100) {
      skipped.invalid++;
      anchor = previous = null;
      continue;
    }
    if (!anchor) {
      anchor = previous = q;
      continue;
    }
    if (q.at_ms - previous.at_ms > 2 * 3600000 || q.at_ms - anchor.at_ms > 12 * 3600000) {
      skipped.gap++;
      anchor = previous = q;
      continue;
    }
    previous = q;
    const delta = q.used_percent - anchor.used_percent;
    if (delta < minimumChange) continue;
    const start = anchor.at_ms, end = q.at_ms;
    anchor = q;
    if (delta > MAX_INTERVAL_PP) {
      skipped.jump++;
      continue;
    }
    const chunk = rows.slice(upperBound(rows, start), upperBound(rows, end));
    if (options.allowedModels && chunk.some(r => r.total > 0 && (!known(r.scope) || r.scope === latest.scope) && !options.allowedModels.has(r.model))) {
      // The quota delta covers the account. Removing only these token rows would
      // assign any charge in the same interval to the remaining models.
      skipped.unlisted_model++;
      continue;
    }
    if (chunk.some(r => !known(r.scope) || r.scope === latest.scope && !hasContext(r))) {
      skipped.unknown++;
      continue;
    }
    if (missing.some(r => r.start <= end && r.end > start)
      || (options.missingAt || []).some(at => at > start && at <= end)) {
      skipped.missing++;
      continue;
    }
    const local = chunk.filter(r => r.scope === latest.scope);
    if (local.some(r => !validUsage(r))) {
      skipped.malformed_usage++;
      continue;
    }
    const groups = {};
    let total = 0;
    for (const row of local) {
      if (!row.total) continue;
      const key = groupKey(row), values = features(row);
      groups[key] ??= [0, 0, 0];
      for (let channel = 0; channel < values.length; channel++) groups[key][channel] += values[channel];
      total += row.total;
    }
    if (!total) {
      skipped.empty++;
      continue;
    }
    observations.push({ start, end, reset_at: cycleReset, delta, groups, total: total / 1e6 });
  }
  const current = anchor && plan === latest.plan && sameCycle(cycleReset, latest.reset_at) ? anchor : null;
  return {
    observations, skipped, snapshots: snapshots.filter(q => q.plan === latest.plan).length,
    planCutoff, latestUncertain,
    progress: {
      interval_required_pp: minimumChange,
      interval_accumulated_pp: current ? previous.used_percent - current.used_percent : 0,
      interval_started_at: current?.at_ms || 0,
      current_cycle_observations: observations.filter(o => sameCycle(o.reset_at, latest.reset_at)).length
    }
  };
}

function normalizedColumns(x) {
  return (x[0] || []).map((_, i) => {
    const column = x.map(row => row[i]), norm = Math.hypot(...column);
    return norm > 0 ? column.map(n => n / norm) : column;
  });
}

function extendBasis(columns, epsilon, initial = []) {
  const basis = [...initial];
  const remaining = columns.map(original => {
    const column = [...original];
    for (const unit of basis) removeProjection(column, unit);
    for (const unit of basis) removeProjection(column, unit);
    return column;
  });
  while (remaining.length) {
    const norms = remaining.map(column => Math.hypot(...column));
    const strongest = norms.indexOf(Math.max(...norms));
    const norm = norms[strongest];
    if (norm < epsilon) break;
    const unit = remaining.splice(strongest, 1)[0].map(value => value / norm);
    basis.push(unit);
    for (const column of remaining) {
      removeProjection(column, unit);
      removeProjection(column, unit);
    }
  }
  return basis;
}

function removeProjection(column, unit) {
  const weight = dot(column, unit);
  for (let i = 0; i < column.length; i++) column[i] -= weight * unit[i];
}

function independentColumns(x) {
  const columns = normalizedColumns(x);
  return columns.length > 0 && extendBasis(columns, RANK_TOLERANCE).length === columns.length;
}

function independentGroup(columns, first, count) {
  const target = columns.slice(first, first + count);
  const others = [...columns.slice(0, first), ...columns.slice(first + count)];
  const nuisance = extendBasis(others, 1e-9);
  return extendBasis(target, RANK_TOLERANCE, nuisance).length === nuisance.length + count;
}

function fitNonnegative(x, y, { prior = 0, penalties } = {}) {
  const norms = (x[0] || []).map((_, j) => Math.hypot(...x.map(row => row[j])));
  if (!norms.length || norms.some(n => !Number.isFinite(n) || n <= 0)) return null;
  const columns = norms.map((norm, j) => x.map(row => row[j] / norm));
  const beta = norms.map(() => 0), residual = [...y];
  for (let iteration = 0; iteration < 4000; iteration++) {
    let change = 0;
    for (let j = 0; j < beta.length; j++) {
      const ridge = penalties?.[j] ?? 0.0001;
      const next = Math.max(0, (dot(columns[j], residual) + beta[j] + ridge * prior * norms[j]) / (1 + ridge));
      const delta = next - beta[j];
      beta[j] = next;
      change = Math.max(change, Math.abs(delta));
      for (let i = 0; i < residual.length; i++) residual[i] -= delta * columns[j][i];
    }
    if (change < 1e-8) return beta.map((v, j) => v / norms[j]);
  }
  return null;
}

function matrix(observations, keys, channels) {
  return observations.map(o => keys.flatMap(key => {
    const group = o.groups[key] || [0, 0, 0];
    return channels ? group : [sum(group)];
  }));
}

function score(predicted, actual) {
  const errors = actual.map((value, i) => predicted[i] - value);
  return { mae: sum(errors.map(Math.abs)) / errors.length, bias: sum(errors) };
}

function passesError(metrics, actual) {
  return metrics.mae <= 1.25 && Math.abs(metrics.bias) <= Math.max(1.5, sum(actual) * 0.20);
}

function beats(candidate, baseline) {
  return candidate <= baseline * 0.90 && baseline - candidate >= 0.15;
}

function trainFit(observations, keys, channels) {
  const x = matrix(observations, keys, channels);
  return independentColumns(x) ? fitNonnegative(x, observations.map(o => o.delta)) : null;
}

function chooseChannelFit(train, keys) {
  if (train.length < keys.length * 18) return null;
  // Use only training data to select complexity. The outer holdout is scored once.
  const count = Math.max(MIN_HOLDOUT, Math.ceil(train.length * 0.25));
  const innerTrain = train.slice(0, -count), selection = train.slice(-count);
  const simple = trainFit(innerTrain, keys, false), separate = trainFit(innerTrain, keys, true);
  if (!simple || !separate || separate.some(rate => rate <= RATE_FLOOR)) return null;
  const actual = selection.map(o => o.delta);
  const simpleScore = score(matrix(selection, keys, false).map(row => dot(row, simple)), actual);
  const separateScore = score(matrix(selection, keys, true).map(row => dot(row, separate)), actual);
  if (!passesError(separateScore, actual) || !beats(separateScore.mae, simpleScore.mae)) return null;
  const fit = trainFit(train, keys, true);
  return fit?.every(rate => rate > RATE_FLOOR) ? fit : null;
}

function supportCount(observations, key) {
  return observations.reduce((count, o) => count + (sum(o.groups[key] || []) > 0 ? 1 : 0), 0);
}

function supportedGroups(observations, keys, minimum) {
  let suitable = keys, usable = observations;
  while (suitable.length) {
    const next = suitable.filter(key => supportCount(usable, key) >= minimum);
    if (next.length === suitable.length) break;
    suitable = next;
    const allowed = new Set(suitable);
    usable = observations.filter(o => Object.keys(o.groups).every(key => allowed.has(key)));
  }
  return { keys: suitable, observations: usable };
}

function calibrate(observations, latest) {
  const ordered = [...observations].sort((a, b) => a.end - b.end || a.start - b.start);
  const keys = [...new Set(ordered.flatMap(o => Object.keys(o.groups)))].sort();
  const support = Object.fromEntries(keys.map(key => [key, supportCount(ordered, key)]));
  const base = {
    mode: 'pending', reason: '样本不足', observations: ordered.length, train: 0, holdout: 0,
    groups: [], unresolved_groups: [], as_of: latest?.at_ms || 0, scope: latest?.scope || UNKNOWN,
    plan: latest?.plan || UNKNOWN, channel_model: false, mae: null, baseline_mae: null, validation_bias: null,
    current_cycle_mae: null, support, validation_support: {},
    requirements: { observations: MIN_OBSERVATIONS, train: MIN_TRAIN, holdout: MIN_HOLDOUT, current_cycle_holdout: MIN_CURRENT, group_current_holdout: MIN_CURRENT },
    current_cycle_holdout: 0
  };
  if (!known(latest?.scope)) return { ...base, reason: '缺少可核对的账户标识' };
  if (ordered.length < MIN_OBSERVATIONS) return base;
  const holdoutCount = Math.max(MIN_HOLDOUT, Math.ceil(ordered.length * 0.25));
  const trainingPool = ordered.slice(0, -holdoutCount), validationPool = ordered.slice(-holdoutCount);
  // Group eligibility uses training only. Drop entire mixed intervals to keep their quota out of other groups.
  const { keys: fittedKeys, observations: train } = supportedGroups(trainingPool, keys, 4);
  const allowed = new Set(fittedKeys);
  const holdout = validationPool.filter(o => Object.keys(o.groups).every(key => allowed.has(key)));
  const current = holdout.filter(o => sameCycle(o.reset_at, latest.reset_at));
  base.train = train.length;
  base.holdout = holdout.length;
  base.excluded_sparse = ordered.length - train.length - holdout.length;
  base.candidate_groups = fittedKeys.length;
  base.requirements.train = Math.max(MIN_TRAIN, fittedKeys.length * 3);
  base.current_cycle_holdout = current.length;
  for (const key of keys) {
    base.validation_support[key] = {
      train: supportCount(train, key),
      holdout: supportCount(holdout, key),
      current: supportCount(current, key)
    };
  }
  if (!fittedKeys.length || train.length < base.requirements.train) return { ...base, reason: '组合较多，需要更多独立用量区间' };
  if (holdout.length < MIN_HOLDOUT) return { ...base, reason: '近期可验证的组合样本不足' };
  if (current.length < MIN_CURRENT) return { ...base, reason: '当前配额周期还需要验证样本' };

  const simpleX = matrix(train, fittedKeys, false), y = train.map(o => o.delta);
  if (!independentColumns(simpleX)) return { ...base, reason: '组合经常同时使用，暂时无法分离系数' };
  const separate = chooseChannelFit(train, fittedKeys);
  const channels = separate !== null;
  const beta = separate || fitNonnegative(simpleX, y);
  const baseline = fitNonnegative(train.map(o => [o.total]), y);
  if (!beta || !baseline) return { ...base, reason: '系数未稳定收敛，继续积累样本' };

  const testY = holdout.map(o => o.delta), testX = matrix(holdout, fittedKeys, channels);
  const measured = score(testX.map(row => dot(row, beta)), testY);
  const baselineScore = score(holdout.map(o => o.total * baseline[0]), testY);
  const recentX = matrix(current, fittedKeys, channels), recentY = current.map(o => o.delta);
  const recentPredicted = recentX.map(row => dot(row, beta));
  const recent = score(recentPredicted, recentY);
  Object.assign(base, {
    channel_model: channels, mae: measured.mae, baseline_mae: baselineScore.mae,
    validation_bias: measured.bias, validation_start: holdout[0].start, current_cycle_mae: recent.mae
  });
  if (!passesError(measured, testY) || !passesError(recent, recentY)) {
    return { ...base, reason: '近期验证误差较大，继续积累样本' };
  }
  // A single total-token group is the baseline itself and can only be tested for absolute error.
  if ((channels || fittedKeys.length > 1) && !beats(measured.mae, baselineScore.mae)) {
    return { ...base, reason: '暂未证实优于统一 token 换算' };
  }

  const recentColumns = normalizedColumns(recentX), width = channels ? 3 : 1;
  const groups = [], unresolved = [];
  for (const key of keys) {
    const index = fittedKeys.indexOf(key);
    const counts = base.validation_support[key], identity = dimensions(key);
    if (index < 0) {
      unresolved.push({ ...identity, reason: '此组合需要更多训练区间' });
      continue;
    }
    const first = index * width, rates = beta.slice(first, first + width);
    const exposed = recentX.flatMap((row, i) => dot(row.slice(first, first + width), rates) >= MIN_EXPOSURE_PP ? [i] : []);
    counts.informative = exposed.length;
    let reason;
    if (rates.some(n => n <= RATE_FLOOR)) reason = '系数落在零边界，暂时无法可靠分离';
    else if (counts.current < MIN_CURRENT) reason = '此组合还需要本周期验证区间';
    else if (exposed.length < MIN_CURRENT) reason = '此组合在本周期验证区间中的用量太少';
    else if (!independentGroup(recentColumns, first, width)) reason = '本周期混用比例接近，暂时无法验证此组合';
    else if (!passesError(score(exposed.map(i => recentPredicted[i]), exposed.map(i => recentY[i])), exposed.map(i => recentY[i]))) {
      reason = '此组合相关区间的近期误差较大';
    }
    if (reason) unresolved.push({ ...identity, reason });
    else groups.push({ ...identity, samples: counts.train, rates, channel_model: channels });
  }
  // Deploy exactly the parameters scored on the holdout.
  return {
    ...base, mode: groups.length ? 'learned' : 'pending',
    reason: groups.length === keys.length ? '已通过时间留出验证'
      : groups.length ? '部分组合已通过时间留出验证' : '各组合仍需本周期的独立验证',
    groups, unresolved_groups: unresolved
  };
}

function provisionalFit(observations, latest) {
  // The pooled rate regularizes the fit. Only estimates with evidence for
  // their own combination are published.
  const weight = o => 2 ** (-(latest.at_ms - o.end) / (7 * DAY));
  const reference = sum(observations.map(o => o.delta * weight(o))) / sum(observations.map(o => o.total * weight(o)));
  const keys = [...new Set(observations.flatMap(o => Object.keys(o.groups)))].sort();
  const support = Object.fromEntries(keys.map(key => [key, supportCount(observations, key)]));
  const current = observations.filter(o => sameCycle(o.reset_at, latest.reset_at));
  const { keys: separated, observations: clean } = supportedGroups(observations, keys, 3);
  const groupRates = {};
  for (const key of keys) {
    const solo = observations.filter(o => Object.keys(o.groups).length === 1 && o.groups[key]);
    const tokens = sum(solo.map(o => o.total * weight(o)));
    if (tokens > 0 && supportCount(current, key)) {
      groupRates[key] = sum(solo.map(o => o.delta * weight(o))) / tokens;
    }
  }
  if (separated.length > 1 && clean.some(o => Object.keys(o.groups).length > 1)
    && independentColumns(matrix(clean, separated, false))) {
    const rootWeights = clean.map(o => Math.sqrt(weight(o)));
    const x = matrix(clean, separated, false).map((row, i) => row.map(n => n * rootWeights[i]));
    const y = clean.map((o, i) => o.delta * rootWeights[i]);
    const penalties = separated.map(key => 4 / supportCount(clean, key));
    const fitted = fitNonnegative(x, y, { prior: reference, penalties });
    separated.forEach((key, i) => {
      if (fitted?.[i] > RATE_FLOOR && supportCount(current, key)) groupRates[key] = fitted[i];
    });
  }
  return { basis: 'interval', group_rates: groupRates, support, observations: observations.length,
    current_observations: current.length };
}

function calibrationReport(usage, quotas, latest, options = {}) {
  const blocks = buildObservations(usage, quotas, latest, options);
  const result = {
    ...calibrate(blocks.observations, latest),
    progress: blocks.progress, skipped: blocks.skipped, snapshot_count: blocks.snapshots,
    plan_cutoff: blocks.planCutoff, historical: null, provisional: null,
    fit_progress: { observations: 0, historical: 0, current: 0, support: {} }
  };
  if (blocks.latestUncertain) {
    Object.assign(result, { mode: 'pending', reason: '最新配额快照存在冲突或回退', groups: [] });
  }
  if (known(latest.scope) && validSnapshot(latest) && !blocks.latestUncertain) {
    const currentStart = latest.reset_at * 1000 - 7 * DAY;
    result.usage_window = { start: currentStart, end: latest.at_ms };
    const listed = usage.filter(row => row.scope === latest.scope && row.at_ms >= currentStart
      && row.at_ms <= latest.at_ms && row.at_ms > blocks.planCutoff
      && (!options.allowedModels || options.allowedModels.has(row.model)));
    const preview = buildObservations(usage, quotas, latest, { ...options, minimumChange: 1 });
    const fit = preview.observations.length ? provisionalFit(preview.observations, latest) : null;
    if (fit) {
      result.fit_progress = {
        observations: fit.observations, historical: fit.observations - fit.current_observations,
        current: fit.current_observations, support: fit.support
      };
    }
    result.provisional = fit && Object.keys(fit.group_rates).length ? fit : null;
    // Allow one percentage point for snapshot rounding. A local subtotal
    // outside the account's recorded usage signals an unreliable conversion.
    const exceedsSnapshot = () => estimateRows(listed, result).known_value > latest.used_percent + 1;
    if (exceedsSnapshot()) {
      result.provisional_warning = '估算合计高于账户快照，暂停应用拟合系数';
      result.provisional = null;
      if (exceedsSnapshot()) Object.assign(result, { mode: 'pending', reason: '系数未通过本周期总量校验', groups: [] });
    }
  }
  // Try the most recent previous cycles first. Archive only validated groups currently awaiting validation.
  if (known(latest.scope) && (result.mode !== 'learned' || result.groups.length < Object.keys(result.support).length)) {
    const recent = quotas.filter(q => q.limit_id === 'codex' && q.window_minutes === 10080
      && q.scope === latest.scope && q.at_ms >= latest.at_ms - LOOKBACK && q.at_ms < latest.at_ms);
    const prior = recent.filter(q => q.plan === latest.plan && validSnapshot(q) && q.reset_at < latest.reset_at - RESET_JITTER)
      .sort((a, b) => b.at_ms - a.at_ms);
    const tried = [];
    const active = new Set(result.groups.map(group => group.key));
    for (const previous of prior) {
      if (tried.some(reset => sameCycle(reset, previous.reset_at))) continue;
      tried.push(previous.reset_at);
      const oldBlocks = buildObservations(usage, recent, previous, options);
      if (oldBlocks.latestUncertain) continue;
      const old = calibrate(oldBlocks.observations, previous);
      const groups = old.groups.filter(group => !active.has(group.key));
      if (groups.length) {
        result.historical = { as_of: old.as_of, reset_at: previous.reset_at, mae: old.mae,
          baseline_mae: old.baseline_mae, groups, unresolved_groups: old.unresolved_groups, reason: old.reason };
        break;
      }
    }
  }
  return result;
}

function estimateRows(rows, calibration) {
  const rates = new Map(calibration.groups.map(group => [group.key, group]));
  const preview = calibration.provisional, window = calibration.usage_window;
  let value = 0, covered = 0, estimated = 0, total = 0, status = 'validated';
  for (const row of rows) {
    total += row.total;
    if (row.scope !== calibration.scope || !validUsage(row)
      || window && !(row.at_ms >= window.start && row.at_ms <= window.end)
      || calibration.plan_cutoff && row.at_ms <= calibration.plan_cutoff) continue;
    const key = hasContext(row) ? groupKey(row) : null;
    const group = calibration.mode === 'learned' && rates.get(key);
    const provisionalRate = preview?.group_rates[key];
    const channelCount = group?.channel_model ? 3 : 1;
    if (group && group.rates.length === channelCount && group.rates.every(n => Number.isFinite(n) && n > RATE_FLOOR)) {
      value += group.channel_model ? dot(features(row), group.rates) : row.total / 1e6 * group.rates[0];
      covered += row.total;
    } else if (Number.isFinite(provisionalRate) && provisionalRate > 0) {
      value += row.total / 1e6 * provisionalRate;
      status = 'provisional';
    } else {
      continue;
    }
    estimated += row.total;
  }
  const complete = total > 0 && estimated === total;
  return {
    value: complete ? value : null, status: complete ? status : null,
    known_value: estimated > 0 ? value : null,
    covered_tokens: covered, estimated_tokens: estimated, total_tokens: total
  };
}

module.exports = { groupKey, dimensions, features, validUsage, buildObservations, independentColumns, fitNonnegative, calibrate, calibrationReport, estimateRows };
