/* Version: 0.28.9
 * Purpose: Pure disk-status helpers for the Cockpit storage panel.
 * Normalizes disk payloads, builds donut segments, derives space alerts,
 * and diffs storage relocation form values. No host calls.
 * Classic browser script; Node tests read it through module.exports.
 * File: helper.disk.status.js
 *
 * Changes in v0.28.9:
 * - normalizeDiskList maps a disks array, and falls back to legacy system and data objects.
 * - buildDonutSegments splits the ring by use percent, with free space as the remainder and app categories sharing the used arc.
 * - deriveDiskAlerts reports critical and warning mounts plus a SeaweedFS ceiling warning.
 * - computeStorageDiff returns relocation flags, new data and file-storage paths, and confirmation lines.
 */

var DISK_SEGMENT_CATALOG = [
  { key: 'db', label: 'Database (db_data)', colorClass: 'disk-seg-db' },
  { key: 'fs', label: 'File storage (fs_data)', colorClass: 'disk-seg-fs' },
  { key: 'state', label: 'State store (state_data)', colorClass: 'disk-seg-state' },
  { key: 'images', label: 'Container images', colorClass: 'disk-seg-images' },
  { key: 'backups', label: 'Backups', colorClass: 'disk-seg-backups' },
  { key: 'updates', label: 'Staged updates', colorClass: 'disk-seg-updates' },
  { key: 'other', label: 'System / other files', colorClass: 'disk-seg-other' },
  { key: 'free', label: 'Free space', colorClass: 'disk-seg-free' }
];

var APP_SEGMENT_KEYS = ['db', 'fs', 'state', 'images', 'backups', 'updates'];
var BYTES_PER_GB = 1024 * 1024 * 1024;

function toNonNeg(value) {
  var n = Number(value);
  if (typeof n !== 'number' || !isFinite(n) || n < 0) return 0;
  return n;
}

function levelForPercent(pct) {
  if (pct >= 95) return 'critical';
  if (pct >= 85) return 'warning';
  return 'ok';
}

function isPlainObject(value) {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function emptyBreakdown() {
  return {
    db: 0,
    fs: 0,
    state: 0,
    images: 0,
    backups: 0,
    updates: 0
  };
}

function readBreakdown(disk) {
  var result = emptyBreakdown();
  if (!disk) return result;
  var source = disk.breakdown;
  if (!isPlainObject(source)) source = disk.segments;
  if (!isPlainObject(source)) return result;
  var i;
  for (i = 0; i < APP_SEGMENT_KEYS.length; i++) {
    result[APP_SEGMENT_KEYS[i]] = toNonNeg(source[APP_SEGMENT_KEYS[i]]);
  }
  return result;
}

function normalizeRoles(roles) {
  var out = [];
  var i;
  if (!Array.isArray(roles)) return out;
  for (i = 0; i < roles.length; i++) {
    if (typeof roles[i] === 'string' && roles[i] !== '') out.push(roles[i]);
  }
  return out;
}

function hasRole(roles, key) {
  var i;
  for (i = 0; i < roles.length; i++) {
    if (roles[i] === key) return true;
  }
  return false;
}

function catalogEntry(key) {
  var i;
  for (i = 0; i < DISK_SEGMENT_CATALOG.length; i++) {
    if (DISK_SEGMENT_CATALOG[i].key === key) return DISK_SEGMENT_CATALOG[i];
  }
  return { key: key, label: key, colorClass: '' };
}

function asString(value) {
  if (value == null) return '';
  return String(value);
}

function readPercent(disk, used, total) {
  if (disk && disk.use_percent != null && disk.use_percent !== '') {
    return Math.min(Math.max(Number(disk.use_percent) || 0, 0), 100);
  }
  if (total > 0) return Math.min(Math.max((used / total) * 100, 0), 100);
  return 0;
}

function normalizeOne(disk) {
  var source = disk || {};
  var total = toNonNeg(source.total_bytes);
  var used = toNonNeg(source.used_bytes);
  var avail = toNonNeg(source.avail_bytes);
  var roles = normalizeRoles(source.roles);
  var mount = asString(source.mount_point);
  var isSystem = source.is_system === true;
  var percent;

  if (source.is_system == null && (mount === '/' || hasRole(roles, 'system'))) {
    isSystem = true;
  }

  percent = readPercent(source, used, Math.max(total, used + avail));

  return {
    mount_point: mount,
    device: asString(source.device),
    fstype: asString(source.fstype),
    is_system: isSystem,
    writable: source.writable !== false,
    total_bytes: total,
    used_bytes: used,
    avail_bytes: avail,
    use_percent: percent,
    level: levelForPercent(percent),
    roles: roles,
    breakdown: readBreakdown(source)
  };
}

function legacySystemDisk(system) {
  var roles = Array.isArray(system.roles) ? system.roles : ['system'];
  return normalizeOne({
    mount_point: system.mount_point || system.path || '/',
    device: system.device,
    fstype: system.fstype,
    is_system: true,
    writable: system.writable,
    total_bytes: system.total_bytes,
    used_bytes: system.used_bytes,
    avail_bytes: system.avail_bytes,
    use_percent: system.use_percent,
    roles: roles,
    breakdown: system.breakdown,
    segments: system.segments
  });
}

function legacyDataDisk(data) {
  return normalizeOne({
    mount_point: data.mount_point || data.path || '',
    device: data.device,
    fstype: data.fstype,
    is_system: data.is_system === true,
    writable: data.writable,
    total_bytes: data.total_bytes,
    used_bytes: data.used_bytes,
    avail_bytes: data.avail_bytes,
    use_percent: data.use_percent,
    roles: data.roles,
    breakdown: data.breakdown,
    segments: data.segments
  });
}

function normalizeDiskList(info) {
  var out = [];
  var i;
  if (info && Array.isArray(info.disks) && info.disks.length > 0) {
    for (i = 0; i < info.disks.length; i++) {
      if (isPlainObject(info.disks[i])) out.push(normalizeOne(info.disks[i]));
    }
    return out;
  }
  if (!isPlainObject(info)) return out;
  if (isPlainObject(info.system)) out.push(legacySystemDisk(info.system));
  if (isPlainObject(info.data)) out.push(legacyDataDisk(info.data));
  return out;
}

function buildDonutSegments(disk, circumference) {
  var source = disk || {};
  var circ = Number(circumference);
  var usedBytes = toNonNeg(source.used_bytes);
  var availBytes = toNonNeg(source.avail_bytes);
  var capacity = Math.max(toNonNeg(source.total_bytes), usedBytes + availBytes, 1);
  var usePct = Math.min(Math.max(Number(source.use_percent) || 0, 0), 100);
  var freePct = 100 - usePct;
  var roles = normalizeRoles(source.roles);
  var breakdown = readBreakdown(source);
  var isSystem = source.is_system === true;
  var knownUsedBytes = 0;
  var scaleDown;
  var otherBytes;
  var shown = {};
  var pctOf = {};
  var segments = [];
  var arcs = [];
  var legend = [];
  var cumulative = 0;
  var usedPctSum = 0;
  var lastUsedIndex = -1;
  var i;
  var key;
  var raw;
  var entry;
  var seg;
  var arcLength;

  if (!(circ > 0)) circ = 2 * Math.PI * 52;

  for (i = 0; i < APP_SEGMENT_KEYS.length; i++) {
    knownUsedBytes += breakdown[APP_SEGMENT_KEYS[i]];
  }

  scaleDown = knownUsedBytes > usedBytes && knownUsedBytes > 0;
  otherBytes = 0;
  if (!scaleDown) {
    otherBytes = Math.max(0, Math.min(usedBytes, capacity) - knownUsedBytes);
  }

  for (i = 0; i < APP_SEGMENT_KEYS.length; i++) {
    key = APP_SEGMENT_KEYS[i];
    raw = breakdown[key];
    if (scaleDown) {
      shown[key] = raw * (usedBytes / knownUsedBytes);
      pctOf[key] = (raw / knownUsedBytes) * usePct;
    } else if (usedBytes > 0) {
      shown[key] = raw;
      pctOf[key] = (raw / usedBytes) * usePct;
    } else {
      shown[key] = 0;
      pctOf[key] = knownUsedBytes > 0 ? (raw / knownUsedBytes) * usePct : 0;
    }
  }

  var otherPct = 0;
  if (scaleDown) {
    otherPct = 0;
  } else if (usedBytes > 0) {
    otherPct = (otherBytes / usedBytes) * usePct;
  } else if (knownUsedBytes === 0) {
    otherPct = usePct;
  }

  for (i = 0; i < APP_SEGMENT_KEYS.length; i++) {
    key = APP_SEGMENT_KEYS[i];
    if (!(breakdown[key] > 0 || hasRole(roles, key))) continue;
    entry = catalogEntry(key);
    segments.push({
      key: key,
      label: entry.label,
      colorClass: entry.colorClass,
      bytes: shown[key],
      pct: pctOf[key]
    });
  }

  if (otherBytes > 0 || otherPct > 0 || isSystem) {
    entry = catalogEntry('other');
    segments.push({
      key: 'other',
      label: entry.label,
      colorClass: entry.colorClass,
      bytes: otherBytes,
      pct: otherPct
    });
  }

  for (i = 0; i < segments.length; i++) {
    if (segments[i].pct > 0) {
      usedPctSum += segments[i].pct;
      lastUsedIndex = i;
    }
  }
  if (lastUsedIndex >= 0) {
    segments[lastUsedIndex].pct += usePct - usedPctSum;
  }

  entry = catalogEntry('free');
  segments.push({
    key: 'free',
    label: entry.label,
    colorClass: entry.colorClass,
    bytes: availBytes,
    pct: freePct
  });

  for (i = 0; i < segments.length; i++) {
    seg = segments[i];
    legend.push({
      key: seg.key,
      label: seg.label,
      colorClass: seg.colorClass,
      bytes: seg.bytes,
      pct: seg.pct
    });
    if (!(seg.pct > 0)) continue;
    arcLength = (seg.pct / 100) * circ;
    arcs.push({
      key: seg.key,
      label: seg.label,
      colorClass: seg.colorClass,
      bytes: seg.bytes,
      pct: seg.pct,
      arcLength: arcLength,
      dashArray: arcLength.toFixed(2) + ' ' + circ.toFixed(2),
      dashOffset: (-cumulative).toFixed(2)
    });
    cumulative += arcLength;
  }

  return {
    circumference: circ,
    usePercent: usePct,
    freePercent: freePct,
    level: levelForPercent(usePct),
    arcs: arcs,
    legend: legend
  };
}

function formatGb(value) {
  var n = Number(value);
  var rounded;
  if (typeof n !== 'number' || !isFinite(n)) return 'unset';
  rounded = Math.round(n * 100) / 100;
  if (Math.abs(rounded - Math.round(rounded)) < 1e-9) return String(Math.round(rounded));
  return String(rounded);
}

function formatBytesAsGb(bytes) {
  return formatGb(toNonNeg(bytes) / BYTES_PER_GB);
}

function diskHostingFs(disks) {
  var i;
  for (i = 0; i < disks.length; i++) {
    if (hasRole(disks[i].roles, 'fs')) return disks[i];
  }
  return null;
}

function deriveDiskAlerts(info) {
  var source = isPlainObject(info) ? info : {};
  var disks = normalizeDiskList(source);
  var criticalDisks = [];
  var warningDisks = [];
  var anyCritical = source.system_critical === true || source.data_critical === true || source.fs_critical === true;
  var anyWarning = false;
  var cfg = isPlainObject(source.storage_config) ? source.storage_config : {};
  var ceilingGb = Number(cfg.fs_volume_max_gb);
  var fsDisk = diskHostingFs(disks);
  var ceilingBytes = 0;
  var ceilingExceedsCapacity = false;
  var fsCeilingWarning = false;
  var fsCeilingMessage = '';
  var i;
  var disk;

  for (i = 0; i < disks.length; i++) {
    disk = disks[i];
    if (disk.use_percent >= 95) {
      anyCritical = true;
      criticalDisks.push(disk.mount_point);
    } else if (disk.use_percent >= 85) {
      anyWarning = true;
      warningDisks.push(disk.mount_point);
    }
  }

  if (isFinite(ceilingGb) && ceilingGb > 0 && fsDisk) {
    ceilingBytes = ceilingGb * BYTES_PER_GB;
    ceilingExceedsCapacity = ceilingBytes > fsDisk.total_bytes || ceilingBytes > fsDisk.avail_bytes;
  }
  if (ceilingExceedsCapacity || cfg.fs_ceiling_exceeds_disk === true) {
    fsCeilingWarning = true;
  }
  if (fsCeilingWarning) {
    if (ceilingExceedsCapacity && fsDisk) {
      fsCeilingMessage = 'SeaweedFS ceiling of ' + formatGb(ceilingGb) + ' GB exceeds capacity on '
        + (fsDisk.mount_point || '/') + ' (' + formatBytesAsGb(fsDisk.avail_bytes) + ' GB free of '
        + formatBytesAsGb(fsDisk.total_bytes) + ' GB).';
    } else {
      fsCeilingMessage = 'SeaweedFS ceiling exceeds the capacity of the disk that hosts file storage.';
    }
  }

  return {
    critical: anyCritical,
    warning: !anyCritical && anyWarning,
    criticalDisks: criticalDisks,
    warningDisks: warningDisks,
    fsCeilingWarning: fsCeilingWarning,
    fsCeilingMessage: fsCeilingMessage
  };
}

function asPath(value) {
  if (value == null) return '';
  return String(value).trim();
}

function stripTrailingSlash(value) {
  var s = String(value);
  while (s.length > 1 && s.charAt(s.length - 1) === '/') {
    s = s.slice(0, s.length - 1);
  }
  return s;
}

function canonicalPath(value) {
  var path = asPath(value);
  if (path === '' || path === 'system') return path;
  return stripTrailingSlash(path);
}

function normalizeMount(value) {
  var s = asPath(value);
  if (s === '' || s === '/' || s === 'system') return '/';
  return stripTrailingSlash(s);
}

function mountFromDataPath(path) {
  var p = canonicalPath(path);
  var parent;
  var slash;
  if (p === '' || p === '/' || p === 'system') return '/';
  if (p.length >= 5 && p.substring(p.length - 5) === '/data') {
    parent = p.substring(0, p.length - 5);
    return parent === '' ? '/' : parent;
  }
  slash = p.lastIndexOf('/');
  if (slash <= 0) return '/';
  return p.substring(0, slash);
}

function currentDbMount(cfg) {
  if (asPath(cfg.effective_db_mount) !== '') return normalizeMount(cfg.effective_db_mount);
  return mountFromDataPath(cfg.app_data_path);
}

function currentFsMount(cfg) {
  var fsPath;
  if (asPath(cfg.effective_fs_mount) !== '') return normalizeMount(cfg.effective_fs_mount);
  fsPath = canonicalPath(cfg.app_fs_data_path);
  if (fsPath === '' || fsPath === 'same') return currentDbMount(cfg);
  if (fsPath === 'system') return '/';
  return mountFromDataPath(fsPath);
}

function requestedDataMount(form) {
  var raw = asPath(form.dataTargetMount);
  if (raw === '' || raw === '/') return '/';
  return stripTrailingSlash(raw);
}

function dataPathForMount(mount) {
  if (mount === '/' || mount === '') return '';
  return mount + '/data';
}

function requestedFsMount(form, dataMount) {
  var raw = asPath(form.fsTargetMount);
  if (raw === '' || raw === 'same') return dataMount;
  if (raw === '/' || raw === 'system') return '/';
  return stripTrailingSlash(raw);
}

function fsPathForTarget(form, newDataPath) {
  var raw = asPath(form.fsTargetMount);
  var mount;
  if (raw === '' || raw === 'same') return '';
  if (raw === '/') return newDataPath === '' ? '' : 'system';
  mount = stripTrailingSlash(raw);
  if (mount === '/' || mount === '') return newDataPath === '' ? '' : 'system';
  return mount + '/data';
}

function readGb(value, fallback) {
  var n = Number(value);
  if (typeof n !== 'number' || !isFinite(n)) return fallback;
  return Math.round(n);
}

function mountLabel(mount) {
  if (!mount || mount === '/') return 'system disk (/)';
  return mount;
}

function pathToken(path) {
  if (path == null || path === '') return 'empty';
  return String(path);
}

function computeStorageDiff(storageConfig, formValues) {
  var cfg = isPlainObject(storageConfig) ? storageConfig : {};
  var form = isPlainObject(formValues) ? formValues : {};
  var currentDataPath = canonicalPath(cfg.app_data_path);
  var currentFsPath = canonicalPath(cfg.app_fs_data_path);
  var currentGb = readGb(cfg.fs_volume_max_gb, 0);
  var newGb = readGb(form.fsVolumeMaxGb, currentGb);
  var newDataMount = requestedDataMount(form);
  var newFsMount = requestedFsMount(form, newDataMount);
  var curDbMount = currentDbMount(cfg);
  var curFsMount = currentFsMount(cfg);
  var newAppDataPath = dataPathForMount(newDataMount);
  var newAppFsDataPath = fsPathForTarget(form, newAppDataPath);
  var relocatesDbState = curDbMount !== newDataMount || currentDataPath !== newAppDataPath;
  var relocatesFs = curFsMount !== newFsMount || currentFsPath !== newAppFsDataPath;
  var changesFsLimit = newGb !== currentGb;
  var summaryLines = [];

  if (curDbMount !== newDataMount) {
    summaryLines.push('Database and state move from ' + mountLabel(curDbMount) + ' to ' + mountLabel(newDataMount) + '.');
  } else if (currentDataPath !== newAppDataPath) {
    summaryLines.push('Database and state path changes from ' + pathToken(currentDataPath) + ' to ' + pathToken(newAppDataPath) + '.');
  }

  if (curFsMount !== newFsMount) {
    summaryLines.push('File storage moves from ' + mountLabel(curFsMount) + ' to ' + mountLabel(newFsMount) + '.');
  } else if (currentFsPath !== newAppFsDataPath) {
    summaryLines.push('File storage path changes from ' + pathToken(currentFsPath) + ' to ' + pathToken(newAppFsDataPath) + '.');
  }

  if (changesFsLimit) {
    summaryLines.push('File storage ceiling changes from ' + formatGb(currentGb) + ' GB to ' + formatGb(newGb) + ' GB.');
  }

  return {
    hasChanges: relocatesDbState || relocatesFs || changesFsLimit,
    relocatesDbState: relocatesDbState,
    relocatesFs: relocatesFs,
    changesFsLimit: changesFsLimit,
    newAppDataPath: newAppDataPath,
    newAppFsDataPath: newAppFsDataPath,
    newFsVolumeMaxGb: newGb,
    summaryLines: summaryLines
  };
}

if (typeof window !== 'undefined') {
  window.DISK_SEGMENT_CATALOG = DISK_SEGMENT_CATALOG;
  window.normalizeDiskList = normalizeDiskList;
  window.buildDonutSegments = buildDonutSegments;
  window.deriveDiskAlerts = deriveDiskAlerts;
  window.computeStorageDiff = computeStorageDiff;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    DISK_SEGMENT_CATALOG: DISK_SEGMENT_CATALOG,
    normalizeDiskList: normalizeDiskList,
    buildDonutSegments: buildDonutSegments,
    deriveDiskAlerts: deriveDiskAlerts,
    computeStorageDiff: computeStorageDiff
  };
}
