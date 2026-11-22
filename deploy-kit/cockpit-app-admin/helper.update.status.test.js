/* Version: 0.28.8
 * Purpose: Table tests for update panel action flags.
 * File: helper.update.status.test.js
 *
 * Changes in v0.28.8:
 * - Delete label is Delete. deleteVisible and deleteTitle follow whether a kit is staged, including while busy.
 * - primaryAction is install, download, or check, and stays the same while busy.
 *
 * Changes in v0.28.5:
 * - Blockers disable install and keep re-check and delete enabled.
 * - Warnings keep install enabled, require acknowledgement, and keep re-check enabled.
 *
 * Changes in v0.26.3:
 * - installLabel is Start update, with the staged version when a kit is downloaded.
 * - checkEnabled is false while busy. checkLabel is Check updates until a releases list is showing, then Refresh updates list.
 *
 * Changes in v0.24.5:
 * - Covers install, download, delete, and fallback notes for staged and selected versions.
 */

'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { updatePanelActions } = require('./helper.update.status.js');

function actions(overrides) {
  return updatePanelActions(Object.assign({
    stagedVersion: '',
    latestVersion: '',
    stagedCompatible: true,
    selectedVersion: '',
    selectedCompatible: true,
    hasList: false,
    busy: false
  }, overrides));
}

test('staged kit newer than the selected release can be installed and the selection can be downloaded', function () {
  var result = actions({
    stagedVersion: '0.24.4-beta2',
    latestVersion: '0.24.3',
    stagedCompatible: true,
    selectedVersion: '0.24.3',
    selectedCompatible: true,
    hasList: true,
    busy: false
  });

  assert.equal(result.installEnabled, true);
  assert.equal(result.installLabel, 'Start update v0.24.4-beta2');
  assert.equal(result.installVersion, '0.24.4-beta2');
  assert.equal(result.downloadEnabled, true);
});

test('selecting the staged version disables download and keeps install for that version', function () {
  var result = actions({
    stagedVersion: '0.24.4',
    latestVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.4',
    selectedCompatible: true,
    hasList: true,
    busy: false
  });

  assert.equal(result.downloadEnabled, false);
  assert.equal(result.installEnabled, true);
  assert.equal(result.installLabel, 'Start update v0.24.4');
  assert.equal(result.installVersion, '0.24.4');
});

test('no staged kit disables install and still allows download of a compatible selection', function () {
  var result = actions({
    stagedVersion: '',
    latestVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.4',
    selectedCompatible: true,
    hasList: true,
    busy: false
  });

  assert.equal(result.installEnabled, false);
  assert.equal(result.installLabel, 'Start update');
  assert.equal(result.installVersion, '');
  assert.equal(result.downloadEnabled, true);
});

test('an incompatible staged kit cannot be installed and can still be deleted', function () {
  var result = actions({
    stagedVersion: '0.24.4',
    latestVersion: '0.24.4',
    stagedCompatible: false,
    selectedVersion: '',
    selectedCompatible: true,
    hasList: false,
    busy: false
  });

  assert.equal(result.installEnabled, false);
  assert.equal(result.deleteEnabled, true);
  assert.equal(result.deleteVisible, true);
  assert.equal(result.deleteLabel, 'Delete');
  assert.equal(result.deleteTitle, 'Delete downloaded update v0.24.4');
});

test('a staged kit with nothing selected can be installed and cannot be downloaded', function () {
  var result = actions({
    stagedVersion: '0.24.4',
    latestVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '',
    selectedCompatible: true,
    hasList: false,
    busy: false
  });

  assert.equal(result.downloadEnabled, false);
  assert.equal(result.installEnabled, true);
  assert.equal(result.installLabel, 'Start update v0.24.4');
  assert.equal(result.installVersion, '0.24.4');
});

test('fallback notes show only when there is no list and the staged kit is empty or matches latest', function () {
  assert.equal(actions({
    hasList: false,
    stagedVersion: '',
    latestVersion: '0.24.3'
  }).showFallbackNotes, true);

  assert.equal(actions({
    hasList: false,
    stagedVersion: '0.24.3',
    latestVersion: '0.24.3'
  }).showFallbackNotes, true);

  assert.equal(actions({
    hasList: false,
    stagedVersion: '0.24.4-beta2',
    latestVersion: '0.24.3'
  }).showFallbackNotes, false);
});

test('delete is enabled only for a staged kit that is not busy', function () {
  var ready = actions({
    stagedVersion: '0.24.4',
    busy: false
  });
  assert.equal(ready.deleteEnabled, true);
  assert.equal(ready.deleteVisible, true);
  assert.equal(ready.deleteLabel, 'Delete');
  assert.equal(ready.deleteTitle, 'Delete downloaded update v0.24.4');

  var empty = actions({
    stagedVersion: '',
    busy: false
  });
  assert.equal(empty.deleteEnabled, false);
  assert.equal(empty.deleteVisible, false);
  assert.equal(empty.deleteLabel, 'Delete');
  assert.equal(empty.deleteTitle, 'Delete download');

  var busy = actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.3',
    selectedCompatible: true,
    busy: true
  });
  assert.equal(busy.deleteEnabled, false);
  assert.equal(busy.deleteVisible, true);
  assert.equal(busy.deleteLabel, 'Delete');
  assert.equal(busy.deleteTitle, 'Delete downloaded update v0.24.4');
  assert.equal(busy.installEnabled, false);
  assert.equal(busy.downloadEnabled, false);
  assert.equal(busy.checkEnabled, false);
});

test('check stays enabled unless busy and its label follows whether a releases list is showing', function () {
  var idle = actions({ hasList: false, busy: false });
  assert.equal(idle.checkEnabled, true);
  assert.equal(idle.checkLabel, 'Check updates');

  var listed = actions({ hasList: true, busy: false });
  assert.equal(listed.checkEnabled, true);
  assert.equal(listed.checkLabel, 'Refresh updates list');

  var busy = actions({ hasList: true, busy: true });
  assert.equal(busy.checkEnabled, false);
  assert.equal(busy.checkLabel, 'Refresh updates list');

  var busyWithoutList = actions({ hasList: false, busy: true });
  assert.equal(busyWithoutList.checkEnabled, false);
  assert.equal(busyWithoutList.checkLabel, 'Check updates');
});

test('precheck blockers disable install and keep recheck and delete enabled', function () {
  var result = actions({
    stagedVersion: '0.24.4',
    latestVersion: '0.24.4',
    stagedCompatible: true,
    busy: false,
    precheckStatus: 'blockers'
  });

  assert.equal(result.installEnabled, false);
  assert.equal(result.recheckEnabled, true);
  assert.equal(result.deleteEnabled, true);
});

test('primaryAction is the next step and stays put while busy', function () {
  assert.equal(actions({
    hasList: false,
    stagedVersion: '',
    selectedVersion: ''
  }).primaryAction, 'check');

  assert.equal(actions({
    stagedVersion: '',
    selectedVersion: '0.24.4',
    selectedCompatible: true
  }).primaryAction, 'download');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.3',
    selectedCompatible: true
  }).primaryAction, 'install');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    precheckStatus: 'warnings'
  }).primaryAction, 'install');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.4',
    selectedCompatible: true,
    precheckStatus: 'blockers'
  }).primaryAction, 'check');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '',
    precheckStatus: 'blockers'
  }).primaryAction, 'check');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    selectedVersion: '0.24.3',
    selectedCompatible: true,
    precheckStatus: 'blockers'
  }).primaryAction, 'download');

  assert.equal(actions({
    stagedVersion: '0.24.4',
    stagedCompatible: true,
    busy: true
  }).primaryAction, 'install');

  assert.equal(actions({
    stagedVersion: '',
    selectedVersion: '0.24.4',
    selectedCompatible: true,
    busy: true
  }).primaryAction, 'download');

  assert.equal(actions({
    stagedVersion: '',
    selectedVersion: '',
    busy: true
  }).primaryAction, 'check');
});

test('precheck warnings keep install enabled and require acknowledgement', function () {
  var result = actions({
    stagedVersion: '0.24.4',
    latestVersion: '0.24.4',
    stagedCompatible: true,
    busy: false,
    precheckStatus: 'warnings'
  });

  assert.equal(result.installEnabled, true);
  assert.equal(result.requiresWarningAck, true);
  assert.equal(result.recheckEnabled, true);
});
