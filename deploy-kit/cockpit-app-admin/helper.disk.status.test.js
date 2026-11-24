/* Version: 0.28.9
 * Purpose: Table tests for disk-status normalization, donut segments, alerts, and storage diffs.
 * File: helper.disk.status.test.js
 *
 * Changes in v0.28.9:
 * - Covers disk normalization, donut segments, space alerts, and storage relocation diffs.
 */

'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {
  DISK_SEGMENT_CATALOG,
  normalizeDiskList,
  buildDonutSegments,
  deriveDiskAlerts,
  computeStorageDiff
} = require('./helper.disk.status.js');

var GB = 1024 * 1024 * 1024;

function sumPct(items) {
  var total = 0;
  var i;
  for (i = 0; i < items.length; i++) total += items[i].pct;
  return total;
}

function keysOf(items) {
  var out = [];
  var i;
  for (i = 0; i < items.length; i++) out.push(items[i].key);
  return out;
}

function disk(overrides) {
  return Object.assign({
    mount_point: '/',
    device: '',
    fstype: '',
    is_system: false,
    writable: true,
    total_bytes: 1000,
    used_bytes: 100,
    avail_bytes: 900,
    use_percent: 10,
    roles: [],
    breakdown: {}
  }, overrides);
}

test('segment catalog lists every category in ring order', function () {
  assert.deepEqual(DISK_SEGMENT_CATALOG, [
    { key: 'db', label: 'Database (db_data)', colorClass: 'disk-seg-db' },
    { key: 'fs', label: 'File storage (fs_data)', colorClass: 'disk-seg-fs' },
    { key: 'state', label: 'State store (state_data)', colorClass: 'disk-seg-state' },
    { key: 'images', label: 'Container images', colorClass: 'disk-seg-images' },
    { key: 'backups', label: 'Backups', colorClass: 'disk-seg-backups' },
    { key: 'updates', label: 'Staged updates', colorClass: 'disk-seg-updates' },
    { key: 'other', label: 'System / other files', colorClass: 'disk-seg-other' },
    { key: 'free', label: 'Free space', colorClass: 'disk-seg-free' }
  ]);
});

test('normalizeDiskList maps a disks array and clamps levels', function () {
  var list = normalizeDiskList({
    disks: [
      {
        mount_point: '/',
        device: '/dev/sda1',
        fstype: 'ext4',
        is_system: true,
        total_bytes: 1000,
        used_bytes: 840,
        avail_bytes: 160,
        use_percent: 84,
        roles: ['system', 'images'],
        breakdown: { db: 10, fs: 0, state: 0, images: 800, backups: 0, updates: 0 }
      },
      {
        mount_point: '/mnt/data',
        device: '/dev/sdb1',
        fstype: 'xfs',
        writable: false,
        total_bytes: 500,
        used_bytes: 425,
        avail_bytes: 75,
        use_percent: 85,
        roles: ['db', 'fs', 'state', 'backups'],
        segments: { db: 100, fs: 200, state: 50, backups: 75 }
      },
      {
        mount_point: '/mnt/full',
        use_percent: 150,
        total_bytes: -20,
        used_bytes: -5,
        avail_bytes: 0,
        roles: ['updates']
      },
      {
        mount_point: '/mnt/hot',
        use_percent: 94,
        total_bytes: 100,
        used_bytes: 94,
        avail_bytes: 6
      },
      {
        mount_point: '/mnt/crit',
        use_percent: 95,
        total_bytes: 100,
        used_bytes: 95,
        avail_bytes: 5
      }
    ],
    system: { use_percent: 99, total_bytes: 1, used_bytes: 1, avail_bytes: 0 }
  });

  assert.equal(list.length, 5);
  assert.equal(list[0].mount_point, '/');
  assert.equal(list[0].device, '/dev/sda1');
  assert.equal(list[0].fstype, 'ext4');
  assert.equal(list[0].is_system, true);
  assert.equal(list[0].writable, true);
  assert.equal(list[0].level, 'ok');
  assert.equal(list[0].use_percent, 84);
  assert.deepEqual(list[0].roles, ['system', 'images']);
  assert.equal(list[0].breakdown.images, 800);
  assert.equal(list[0].breakdown.db, 10);
  assert.equal(list[0].breakdown.updates, 0);

  assert.equal(list[1].writable, false);
  assert.equal(list[1].level, 'warning');
  assert.equal(list[1].use_percent, 85);
  assert.equal(list[1].fstype, 'xfs');
  assert.equal(list[1].breakdown.db, 100);
  assert.equal(list[1].breakdown.fs, 200);
  assert.equal(list[1].breakdown.state, 50);
  assert.equal(list[1].breakdown.images, 0);
  assert.equal(list[1].breakdown.backups, 75);
  assert.equal(list[1].breakdown.updates, 0);

  assert.equal(list[2].use_percent, 100);
  assert.equal(list[2].level, 'critical');
  assert.equal(list[2].total_bytes, 0);
  assert.equal(list[2].used_bytes, 0);
  assert.equal(list[2].writable, true);
  assert.equal(list[2].device, '');
  assert.equal(list[2].fstype, '');

  assert.equal(list[3].level, 'warning');
  assert.equal(list[4].level, 'critical');
  assert.equal(list[4].use_percent, 95);
});

test('normalizeDiskList derives percent when it is missing and keeps an explicit zero', function () {
  var derived = normalizeDiskList({
    disks: [{
      mount_point: '/mnt/data',
      total_bytes: 200,
      used_bytes: 50,
      avail_bytes: 150
    }]
  });
  assert.equal(derived[0].use_percent, 25);
  assert.equal(derived[0].level, 'ok');
  assert.equal(derived[0].is_system, false);

  var zero = normalizeDiskList({
    disks: [{
      mount_point: '/mnt/data',
      total_bytes: 200,
      used_bytes: 50,
      avail_bytes: 150,
      use_percent: 0
    }]
  });
  assert.equal(zero[0].use_percent, 0);
  assert.equal(zero[0].level, 'ok');
});

test('normalizeDiskList falls back to legacy system and data objects', function () {
  var list = normalizeDiskList({
    disks: [],
    system: {
      use_percent: 90,
      total_bytes: 100,
      used_bytes: 90,
      avail_bytes: 10,
      device: '/dev/nvme0n1p2',
      fstype: 'ext4'
    },
    data: {
      path: '/mnt/data',
      use_percent: 10,
      total_bytes: 1000,
      used_bytes: 100,
      avail_bytes: 900,
      breakdown: { db: 40, fs: 60 }
    }
  });

  assert.equal(list.length, 2);
  assert.equal(list[0].mount_point, '/');
  assert.equal(list[0].is_system, true);
  assert.deepEqual(list[0].roles, ['system']);
  assert.equal(list[0].level, 'warning');
  assert.equal(list[0].device, '/dev/nvme0n1p2');
  assert.equal(list[0].fstype, 'ext4');
  assert.equal(list[1].mount_point, '/mnt/data');
  assert.equal(list[1].is_system, false);
  assert.deepEqual(list[1].roles, []);
  assert.equal(list[1].level, 'ok');
  assert.equal(list[1].breakdown.db, 40);
  assert.equal(list[1].breakdown.fs, 60);

  var systemOnly = normalizeDiskList({
    system: { use_percent: 96, total_bytes: 10, used_bytes: 10, avail_bytes: 0 }
  });
  assert.equal(systemOnly.length, 1);
  assert.equal(systemOnly[0].level, 'critical');

  assert.deepEqual(normalizeDiskList(null), []);
  assert.deepEqual(normalizeDiskList({}), []);
});

test('a root mount without an explicit flag is treated as the system disk', function () {
  var list = normalizeDiskList({
    disks: [{ mount_point: '/', use_percent: 10, total_bytes: 10, used_bytes: 1, avail_bytes: 9 }]
  });
  assert.equal(list[0].is_system, true);

  var explicit = normalizeDiskList({
    disks: [{
      mount_point: '/',
      is_system: false,
      use_percent: 10,
      total_bytes: 10,
      used_bytes: 1,
      avail_bytes: 9
    }]
  });
  assert.equal(explicit[0].is_system, false);
});

test('used arcs occupy use percent of the ring and free occupies the rest', function () {
  var result = buildDonutSegments(disk({
    total_bytes: 1000,
    used_bytes: 780,
    avail_bytes: 220,
    use_percent: 78,
    is_system: true,
    roles: ['system', 'db'],
    breakdown: { db: 300, fs: 180 }
  }), 1000);

  assert.equal(result.circumference, 1000);
  assert.equal(result.usePercent, 78);
  assert.equal(result.freePercent, 22);
  assert.equal(result.level, 'ok');
  assert.deepEqual(keysOf(result.arcs), ['db', 'fs', 'other', 'free']);
  assert.equal(result.arcs[0].pct, 30);
  assert.equal(result.arcs[1].pct, 18);
  assert.equal(result.arcs[2].pct, 30);
  assert.equal(result.arcs[3].pct, 22);
  assert.equal(result.arcs[0].bytes, 300);
  assert.equal(result.arcs[1].bytes, 180);
  assert.equal(result.arcs[2].bytes, 300);
  assert.equal(result.arcs[3].bytes, 220);
  assert.equal(result.arcs[0].arcLength + result.arcs[1].arcLength + result.arcs[2].arcLength, 780);
  assert.equal(result.arcs[3].arcLength, 220);
  assert.equal(result.arcs[0].label, 'Database (db_data)');
  assert.equal(result.arcs[0].colorClass, 'disk-seg-db');
  assert.equal(result.arcs[0].dashArray, '300.00 1000.00');
  assert.equal(result.arcs[0].dashOffset, '0.00');
  assert.equal(result.arcs[1].dashArray, '180.00 1000.00');
  assert.equal(result.arcs[1].dashOffset, '-300.00');
  assert.equal(result.arcs[2].dashOffset, '-480.00');
  assert.equal(result.arcs[3].label, 'Free space');
  assert.equal(result.arcs[3].colorClass, 'disk-seg-free');
  assert.equal(result.arcs[3].dashOffset, '-780.00');
  assert.equal(sumPct(result.arcs), 100);
  assert.deepEqual(keysOf(result.legend), ['db', 'fs', 'other', 'free']);
});

test('free percent follows use percent even when byte totals disagree', function () {
  var result = buildDonutSegments(disk({
    total_bytes: 1000,
    used_bytes: 500,
    avail_bytes: 999,
    use_percent: 78,
    breakdown: { db: 500 }
  }), 1000);

  assert.equal(result.freePercent, 22);
  assert.equal(result.arcs[result.arcs.length - 1].key, 'free');
  assert.equal(result.arcs[result.arcs.length - 1].pct, 22);
  assert.equal(result.arcs[result.arcs.length - 1].bytes, 999);
  assert.equal(result.arcs[result.arcs.length - 1].arcLength, 220);
});

test('a missing breakdown assigns the whole used arc to other files', function () {
  var result = buildDonutSegments(disk({
    used_bytes: 500,
    avail_bytes: 500,
    use_percent: 50,
    roles: ['db'],
    breakdown: {}
  }), 200);

  assert.deepEqual(keysOf(result.arcs), ['other', 'free']);
  assert.equal(result.arcs[0].pct, 50);
  assert.equal(result.arcs[0].bytes, 500);
  assert.equal(result.arcs[0].arcLength, 100);
  assert.equal(result.arcs[1].pct, 50);
  assert.deepEqual(keysOf(result.legend), ['db', 'other', 'free']);
  assert.equal(result.legend[0].bytes, 0);
  assert.equal(result.legend[0].pct, 0);
  assert.equal(result.legend[0].label, 'Database (db_data)');
});

test('a role with no bytes stays in the legend and a full disk drops the free arc', function () {
  var result = buildDonutSegments(disk({
    used_bytes: 780,
    avail_bytes: 0,
    use_percent: 100,
    is_system: true,
    roles: ['db', 'state'],
    breakdown: { db: 780 }
  }), 100);

  assert.equal(result.level, 'critical');
  assert.deepEqual(keysOf(result.arcs), ['db']);
  assert.equal(result.arcs[0].pct, 100);
  assert.deepEqual(keysOf(result.legend), ['db', 'state', 'other', 'free']);
  assert.equal(result.legend[1].key, 'state');
  assert.equal(result.legend[1].bytes, 0);
  assert.equal(result.legend[1].pct, 0);
  assert.equal(result.legend[1].label, 'State store (state_data)');
  assert.equal(result.legend[2].bytes, 0);
  assert.equal(result.legend[2].pct, 0);
  assert.equal(result.legend[3].pct, 0);
  assert.equal(result.legend[3].bytes, 0);
});

test('category shares scale down when the breakdown overshoots used bytes', function () {
  var result = buildDonutSegments(disk({
    used_bytes: 1000,
    avail_bytes: 1000,
    use_percent: 50,
    breakdown: { db: 900, fs: 900 }
  }), 100);

  assert.deepEqual(keysOf(result.arcs), ['db', 'fs', 'free']);
  assert.equal(result.arcs[0].pct, 25);
  assert.equal(result.arcs[1].pct, 25);
  assert.equal(result.arcs[2].pct, 50);
  assert.equal(result.arcs[0].bytes, 500);
  assert.equal(result.arcs[1].bytes, 500);
  assert.equal(sumPct(result.arcs), 100);
  assert.deepEqual(keysOf(result.legend), ['db', 'fs', 'free']);
});

test('uneven category shares still sum with free space to 100 percent', function () {
  var result = buildDonutSegments(disk({
    used_bytes: 3,
    avail_bytes: 3,
    use_percent: 50,
    breakdown: { db: 1, fs: 1 }
  }), 100);

  assert.equal(sumPct(result.arcs), 100);
  assert.equal(result.freePercent, 50);
  assert.equal(result.arcs[result.arcs.length - 1].key, 'free');
  assert.ok(Math.abs(result.arcs[0].pct - (50 / 3)) < 1e-9);
});

test('warning and critical levels follow the use percent thresholds', function () {
  assert.equal(buildDonutSegments(disk({ use_percent: 90 })).level, 'warning');
  assert.equal(buildDonutSegments(disk({ use_percent: 95 })).level, 'critical');
  assert.equal(buildDonutSegments(disk({ use_percent: 10 })).level, 'ok');
});

test('omitted or non-positive circumference falls back to the default ring', function () {
  var expected = 2 * Math.PI * 52;
  var sample = disk({ use_percent: 10, used_bytes: 10, avail_bytes: 90 });
  assert.equal(buildDonutSegments(sample).circumference, expected);
  assert.equal(buildDonutSegments(sample, 0).circumference, expected);
  assert.equal(buildDonutSegments(sample, -4).circumference, expected);
  assert.equal(buildDonutSegments(sample, 50).circumference, 50);
});

test('deriveDiskAlerts separates critical mounts, warning mounts, and critical flags', function () {
  var quiet = deriveDiskAlerts({
    disks: [
      disk({ mount_point: '/', use_percent: 10, roles: ['system'] }),
      disk({ mount_point: '/mnt/data', use_percent: 20, roles: ['db'] })
    ]
  });
  assert.equal(quiet.critical, false);
  assert.equal(quiet.warning, false);
  assert.deepEqual(quiet.criticalDisks, []);
  assert.deepEqual(quiet.warningDisks, []);
  assert.equal(quiet.fsCeilingWarning, false);
  assert.equal(quiet.fsCeilingMessage, '');

  var warn = deriveDiskAlerts({
    disks: [
      disk({ mount_point: '/', use_percent: 86, roles: ['system'] }),
      disk({ mount_point: '/mnt/data', use_percent: 10, roles: ['db'] })
    ]
  });
  assert.equal(warn.critical, false);
  assert.equal(warn.warning, true);
  assert.deepEqual(warn.warningDisks, ['/']);
  assert.deepEqual(warn.criticalDisks, []);

  var hot = deriveDiskAlerts({
    disks: [
      disk({ mount_point: '/', use_percent: 95, roles: ['system'] }),
      disk({ mount_point: '/mnt/data', use_percent: 90, roles: ['db'] }),
      disk({ mount_point: '/mnt/archive', use_percent: 94, roles: ['backups'] })
    ]
  });
  assert.equal(hot.critical, true);
  assert.equal(hot.warning, false);
  assert.deepEqual(hot.criticalDisks, ['/']);
  assert.deepEqual(hot.warningDisks, ['/mnt/data', '/mnt/archive']);

  var flagged = deriveDiskAlerts({
    system_critical: true,
    disks: [disk({ mount_point: '/mnt/data', use_percent: 90, roles: ['db'] })]
  });
  assert.equal(flagged.critical, true);
  assert.equal(flagged.warning, false);
  assert.deepEqual(flagged.criticalDisks, []);
  assert.deepEqual(flagged.warningDisks, ['/mnt/data']);

  assert.equal(deriveDiskAlerts({ data_critical: true }).critical, true);
  assert.equal(deriveDiskAlerts({ fs_critical: true }).critical, true);
  assert.equal(deriveDiskAlerts({ system_critical: false, data_critical: false, fs_critical: false }).critical, false);
});

test('legacy payloads still raise warning and critical alerts', function () {
  var warn = deriveDiskAlerts({
    system: { use_percent: 90, total_bytes: 100, used_bytes: 90, avail_bytes: 10 },
    data: { path: '/mnt/data', use_percent: 10, total_bytes: 100, used_bytes: 10, avail_bytes: 90 }
  });
  assert.equal(warn.warning, true);
  assert.equal(warn.critical, false);
  assert.deepEqual(warn.warningDisks, ['/']);

  var crit = deriveDiskAlerts({
    system_critical: false,
    data_critical: true,
    data: { path: '/mnt/data', use_percent: 10, total_bytes: 100, used_bytes: 10, avail_bytes: 90 }
  });
  assert.equal(crit.critical, true);
  assert.equal(crit.warning, false);
});

test('SeaweedFS ceiling warning compares the configured max with the file-storage disk', function () {
  var fsDisk = disk({
    mount_point: '/mnt/data',
    use_percent: 80,
    total_bytes: 200 * GB,
    used_bytes: 160 * GB,
    avail_bytes: 40 * GB,
    roles: ['fs', 'db'],
    breakdown: { fs: 100 * GB, db: 60 * GB }
  });

  var overFree = deriveDiskAlerts({
    disks: [fsDisk],
    storage_config: { fs_volume_max_gb: 100 }
  });
  assert.equal(overFree.fsCeilingWarning, true);
  assert.equal(overFree.critical, false);
  assert.equal(overFree.warning, false);
  assert.equal(
    overFree.fsCeilingMessage,
    'SeaweedFS ceiling of 100 GB exceeds capacity on /mnt/data (40 GB free of 200 GB).'
  );

  var fits = deriveDiskAlerts({
    disks: [fsDisk],
    storage_config: { fs_volume_max_gb: 40 }
  });
  assert.equal(fits.fsCeilingWarning, false);
  assert.equal(fits.fsCeilingMessage, '');

  var overTotal = deriveDiskAlerts({
    disks: [fsDisk],
    storage_config: { fs_volume_max_gb: 250 }
  });
  assert.equal(overTotal.fsCeilingWarning, true);
  assert.equal(
    overTotal.fsCeilingMessage,
    'SeaweedFS ceiling of 250 GB exceeds capacity on /mnt/data (40 GB free of 200 GB).'
  );

  var flaggedOnly = deriveDiskAlerts({
    disks: [fsDisk],
    storage_config: { fs_volume_max_gb: 10, fs_ceiling_exceeds_disk: true }
  });
  assert.equal(flaggedOnly.fsCeilingWarning, true);
  assert.equal(
    flaggedOnly.fsCeilingMessage,
    'SeaweedFS ceiling exceeds the capacity of the disk that hosts file storage.'
  );

  var flaggedAndOver = deriveDiskAlerts({
    disks: [fsDisk],
    storage_config: { fs_volume_max_gb: 100, fs_ceiling_exceeds_disk: true }
  });
  assert.equal(
    flaggedAndOver.fsCeilingMessage,
    'SeaweedFS ceiling of 100 GB exceeds capacity on /mnt/data (40 GB free of 200 GB).'
  );

  var noFsRole = deriveDiskAlerts({
    disks: [disk({ mount_point: '/', use_percent: 10, roles: ['system'], total_bytes: GB, avail_bytes: GB })],
    storage_config: { fs_volume_max_gb: 5000 }
  });
  assert.equal(noFsRole.fsCeilingWarning, false);
  assert.equal(noFsRole.fsCeilingMessage, '');
});

function storage(overrides) {
  return Object.assign({
    app_data_path: '',
    app_fs_data_path: '',
    effective_db_mount: '/',
    effective_fs_mount: '/',
    fs_volume_max_gb: 100
  }, overrides);
}

test('computeStorageDiff reports no changes when the form matches the current layout', function () {
  var same = computeStorageDiff(storage(), {
    dataTargetMount: '/',
    fsTargetMount: 'same',
    fsVolumeMaxGb: 100
  });
  assert.equal(same.hasChanges, false);
  assert.equal(same.relocatesDbState, false);
  assert.equal(same.relocatesFs, false);
  assert.equal(same.changesFsLimit, false);
  assert.equal(same.newAppDataPath, '');
  assert.equal(same.newAppFsDataPath, '');
  assert.equal(same.newFsVolumeMaxGb, 100);
  assert.deepEqual(same.summaryLines, []);

  var explicitSystem = computeStorageDiff(storage(), {
    dataTargetMount: '/',
    fsTargetMount: '/',
    fsVolumeMaxGb: 100
  });
  assert.equal(explicitSystem.hasChanges, false);
  assert.equal(explicitSystem.newAppFsDataPath, '');

  var alreadySplit = computeStorageDiff(storage({
    app_data_path: '/mnt/disk1/data',
    app_fs_data_path: 'system',
    effective_db_mount: '/mnt/disk1',
    effective_fs_mount: '/',
    fs_volume_max_gb: 100
  }), {
    dataTargetMount: '/mnt/disk1',
    fsTargetMount: '/',
    fsVolumeMaxGb: 100
  });
  assert.equal(alreadySplit.hasChanges, false);
  assert.equal(alreadySplit.newAppDataPath, '/mnt/disk1/data');
  assert.equal(alreadySplit.newAppFsDataPath, 'system');
  assert.deepEqual(alreadySplit.summaryLines, []);
});

test('moving the data disk also moves file storage when it follows the data path', function () {
  var moved = computeStorageDiff(storage(), {
    dataTargetMount: '/mnt/disk1/',
    fsTargetMount: 'same',
    fsVolumeMaxGb: 100
  });
  assert.equal(moved.hasChanges, true);
  assert.equal(moved.relocatesDbState, true);
  assert.equal(moved.relocatesFs, true);
  assert.equal(moved.changesFsLimit, false);
  assert.equal(moved.newAppDataPath, '/mnt/disk1/data');
  assert.equal(moved.newAppFsDataPath, '');
  assert.equal(moved.newFsVolumeMaxGb, 100);
  assert.deepEqual(moved.summaryLines, [
    'Database and state move from system disk (/) to /mnt/disk1.',
    'File storage moves from system disk (/) to /mnt/disk1.'
  ]);
});

test('file storage can move on its own and the ceiling can change with it', function () {
  var moved = computeStorageDiff(storage({
    app_data_path: '/mnt/disk1/data',
    app_fs_data_path: '',
    effective_db_mount: '/mnt/disk1',
    effective_fs_mount: '/mnt/disk1',
    fs_volume_max_gb: 100
  }), {
    dataTargetMount: '/mnt/disk1',
    fsTargetMount: '/mnt/disk2',
    fsVolumeMaxGb: 200
  });
  assert.equal(moved.relocatesDbState, false);
  assert.equal(moved.relocatesFs, true);
  assert.equal(moved.changesFsLimit, true);
  assert.equal(moved.hasChanges, true);
  assert.equal(moved.newAppDataPath, '/mnt/disk1/data');
  assert.equal(moved.newAppFsDataPath, '/mnt/disk2/data');
  assert.equal(moved.newFsVolumeMaxGb, 200);
  assert.deepEqual(moved.summaryLines, [
    'File storage moves from /mnt/disk1 to /mnt/disk2.',
    'File storage ceiling changes from 100 GB to 200 GB.'
  ]);
});

test('pinning file storage to the system disk while data leaves it records the system path', function () {
  var pinned = computeStorageDiff(storage(), {
    dataTargetMount: '/mnt/disk1',
    fsTargetMount: '/',
    fsVolumeMaxGb: 100
  });
  assert.equal(pinned.relocatesDbState, true);
  assert.equal(pinned.relocatesFs, true);
  assert.equal(pinned.changesFsLimit, false);
  assert.equal(pinned.newAppDataPath, '/mnt/disk1/data');
  assert.equal(pinned.newAppFsDataPath, 'system');
  assert.deepEqual(pinned.summaryLines, [
    'Database and state move from system disk (/) to /mnt/disk1.',
    'File storage path changes from empty to system.'
  ]);
});

test('a path change on the same mount is a database relocation', function () {
  var changed = computeStorageDiff(storage({
    app_data_path: '',
    app_fs_data_path: '',
    effective_db_mount: '/mnt/disk1',
    effective_fs_mount: '/mnt/disk1'
  }), {
    dataTargetMount: '/mnt/disk1',
    fsTargetMount: 'same',
    fsVolumeMaxGb: 100
  });
  assert.equal(changed.relocatesDbState, true);
  assert.equal(changed.relocatesFs, false);
  assert.equal(changed.newAppDataPath, '/mnt/disk1/data');
  assert.equal(changed.newAppFsDataPath, '');
  assert.deepEqual(changed.summaryLines, [
    'Database and state path changes from empty to /mnt/disk1/data.'
  ]);
});

test('effective mounts can be derived from the current paths', function () {
  var same = computeStorageDiff({
    app_data_path: '/mnt/disk1/data',
    app_fs_data_path: '/mnt/disk2/data',
    fs_volume_max_gb: 80
  }, {
    dataTargetMount: '/mnt/disk1',
    fsTargetMount: '/mnt/disk2',
    fsVolumeMaxGb: 80
  });
  assert.equal(same.hasChanges, false);
  assert.equal(same.newAppDataPath, '/mnt/disk1/data');
  assert.equal(same.newAppFsDataPath, '/mnt/disk2/data');
  assert.equal(same.newFsVolumeMaxGb, 80);
  assert.deepEqual(same.summaryLines, []);
});

test('a ceiling-only edit does not relocate either store', function () {
  var changed = computeStorageDiff(storage(), {
    dataTargetMount: '/',
    fsTargetMount: 'same',
    fsVolumeMaxGb: 250
  });
  assert.equal(changed.hasChanges, true);
  assert.equal(changed.relocatesDbState, false);
  assert.equal(changed.relocatesFs, false);
  assert.equal(changed.changesFsLimit, true);
  assert.equal(changed.newFsVolumeMaxGb, 250);
  assert.deepEqual(changed.summaryLines, [
    'File storage ceiling changes from 100 GB to 250 GB.'
  ]);
});

test('browser globals expose the helpers next to module.exports', function () {
  var sandbox = { module: { exports: {} }, window: {} };
  var code = fs.readFileSync(path.join(__dirname, 'helper.disk.status.js'), 'utf8');
  vm.runInNewContext(code, sandbox);
  assert.equal(typeof sandbox.window.normalizeDiskList, 'function');
  assert.equal(typeof sandbox.window.buildDonutSegments, 'function');
  assert.equal(typeof sandbox.window.deriveDiskAlerts, 'function');
  assert.equal(typeof sandbox.window.computeStorageDiff, 'function');
  assert.equal(sandbox.window.DISK_SEGMENT_CATALOG.length, 8);
  assert.equal(sandbox.window.DISK_SEGMENT_CATALOG[0].key, 'db');
  assert.equal(sandbox.window.DISK_SEGMENT_CATALOG[7].key, 'free');
  assert.equal(typeof sandbox.module.exports.normalizeDiskList, 'function');
  assert.equal(sandbox.module.exports.DISK_SEGMENT_CATALOG, sandbox.window.DISK_SEGMENT_CATALOG);
});
