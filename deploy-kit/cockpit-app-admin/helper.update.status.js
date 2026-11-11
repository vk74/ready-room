/* Version: 0.26.3
 * Purpose: Pure action flags for the Cockpit updates panel.
 * Decides whether check, install, download, and delete are enabled, and which labels to show,
 * from the staged kit, the selected release, and whether a releases list is on screen.
 * No host calls. Classic browser script; Node tests read it through module.exports.
 * File: helper.update.status.js
 *
 * Changes in v0.26.3:
 * - updatePanelActions: check stays enabled unless the panel is busy. Its label is Check updates until a releases list is showing, then Refresh updates list.
 * - installLabel is Start update, with the staged version when a kit is downloaded.
 *
 * Changes in v0.24.5:
 * - updatePanelActions: install, download, and delete flags and labels, plus fallback release notes.
 */

function versionString(value) {
  return typeof value === 'string' ? value : '';
}

function updatePanelActions(input) {
  var stagedVersion = versionString(input.stagedVersion);
  var latestVersion = versionString(input.latestVersion);
  var selectedVersion = versionString(input.selectedVersion);
  var hasStaged = stagedVersion !== '';
  var hasSelected = selectedVersion !== '';
  var busy = input.busy === true;

  return {
    checkEnabled: !busy,
    checkLabel: input.hasList === true ? 'Refresh updates list' : 'Check updates',
    installEnabled: hasStaged && input.stagedCompatible !== false && !busy,
    installLabel: hasStaged ? ('Start update v' + stagedVersion) : 'Start update',
    installVersion: stagedVersion,
    downloadEnabled: hasSelected && input.selectedCompatible !== false && selectedVersion !== stagedVersion && !busy,
    deleteEnabled: hasStaged && !busy,
    deleteLabel: hasStaged ? ('Delete v' + stagedVersion) : 'Delete download',
    showFallbackNotes: input.hasList === false && (!hasStaged || stagedVersion === latestVersion)
  };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { updatePanelActions };
}
