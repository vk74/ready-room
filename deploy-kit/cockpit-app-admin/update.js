/* Version: 0.26.3
 * Purpose: Main logic for the Cockpit updates panel.
 * Handles check for updates (list releases), download of the selected release, delete of the staged kit,
 * and install of the staged kit (detached + polling).
 * Communicates with host scripts via update-dispatch.sh using cockpit.spawn().
 * Install, download, and delete flags come from updatePanelActions in helper.update.status.js.
 * State machine: IDLE | INSTALLING | FINISHED_SUCCESS | FINISHED_FAILED.
 * On init, calls update-progress first to reconnect to an in-progress update if any.
 * Cockpit package; filename: update.js
 *
 * Changes in v0.26.3:
 * - Install progress and output stay in the panel. Removed the full-screen overlay and Dismiss button.
 * - Download, delete, check, install, and Clear stay available after a finished install and reset that finished state.
 * - After a finished install, the status badge follows a staged kit or a releases list when one is present.
 * - Install is one start-update process. The sudo password is sent on its stdin and cleared from memory.
 * - Update output highlights phase headings, banners, rules, and status markers.
 * - Version card shows installed on and last updated. Last checked uses the same timestamp formatting.
 * - The check button label and enabled state come from updatePanelActions. There is no separate refresh button.
 * - Checking for updates also re-reads the GitHub access key status.
 *
 * Changes in v0.26.2:
 * - Dispatch path is /usr/local/share/cockpit/app-admin/update-dispatch.sh.
 *
 * Changes in v0.25.5:
 * - Strip ANSI escape codes from overlay output chunks during progress polling.
 * - Populate Output from update-progress logContent when reconnecting to a finished update on init.
 *
 * Changes in v0.25.4:
 * - Install reads the start-update result from the spawn stream. Cockpit delivers
 *   that output only to the stream callback, so the promise body is empty and was
 *   shown as "Failed to start update: status idle" while apply-update.sh was running.
 * - The Output panel receives the same apply-update log as the progress overlay.
 *
 * Changes in v0.25.2:
 * - Latest available uses the same unknown-to-em-dash formatting as the installed version.
 * - Download, install, and delete stay in sync with panelActions during install and finished states.
 *   The status badge and fallback notes are left unchanged while an install is in progress or just finished.
 * - Fallback notes stay hidden when the installation is up to date, and when nothing newer is available and no kit is staged.
 * - Check for updates and Refresh updates list are disabled while an operation is running or an install is in progress.
 * - A successful install clears the releases list and fallback notes before status is re-read.
 * - Cockpit panel install completion re-reads system status.
 * - Refresh updates list, opening Updates, and window focus / tab visibility re-read system status and the GitHub key status.
 *   Focus and visibility refresh only while Updates is visible, no operation is running, and an install is not in progress.
 *
 * Changes in v0.24.5:
 * - Version card shows the staged kit under Downloaded. Refresh re-reads local status.
 * - Delete download asks for confirmation, then discard-download, and does not clear the releases list.
 * - Install, download, and delete follow updatePanelActions. Install uses the staged kit, not the selected release.
 * - Install reads status before the sudo modal and passes that staged version to start-update.
 * - A start-update result other than started or already_running is shown as an error, and the Cockpit panel install is not started.
 * - Beta checkbox persists include-beta and reloads status. It no longer clears latest or downloaded in memory.
 * - Opening Updates re-reads status without clearing the releases list.
 * - With no releases list, updates.json notes show only when the staged kit is empty or matches latest.
 * - Status badge follows the staged kit: a downloaded kit is ready to install even when the last check found nothing newer.
 *
 * Changes in v0.23.10:
 * - Consumes .accent-* / .inset-table catalog (was .evi-*).
 *
 * Changes in v0.23.5:
 * - github-token-status / set-github-token via dispatch; badge and save flow.
 * - Token is sent on stdin and never stored on state or written to the output panel.
 * - Check for updates is not gated on whether a key is saved.
 * - Save parses the last JSON object from spawn output (Cockpit err:out).
 *
 * Changes in v0.21.8:
 * - onReleaseSelected/autoSelectRecommended now call showReleaseNotes() with the
 *   selected/recommended release's releaseNotes (list-releases.sh now returns this
 *   field per-release) so notes are visible before the user downloads/installs.
 * - showReleaseNotes(): shows a "no additional notes for this release" placeholder
 *   instead of hiding the box when notes are empty (dev left --note blank).
 *
 * Changes in v1.4.4:
 * - ensureUpdateDialogPortaled: move overlay/sudo modal to document.body (avoids overflow clipping)
 * - launchBothProcesses: show progress overlay when update starts
 * - installUpdate: reset FINISHED_* UI state so retry after failed update works
 *
 * Changes in v1.4.3:
 * - formatInstalledVersion: hide placeholder "unknown" in INSTALLED VERSION card (show em dash)
 *
 * Changes in v1.4.2:
 * - DISPATCH_PATH updated to /usr/local/share/cockpit/evi-admin/evi-update-dispatch.sh
 *   (update panel is now embedded inside evi-admin; dispatch script lives alongside admin).
 *
 * Changes in v1.4.1:
 * - sudo modal now includes install description (replaces old window.confirm confirmation step)
 * - showSudoModal() populates version label in modal title
 * - Modal button renamed from "Verify & Install" to "Install"
 * - Added sudo-modal-version span, sudo-what list, sudo-note paragraph to modal HTML
 *
 * Changes in v1.4.0:
 * - installUpdate() now shows sudo password modal instead of launching start-update directly
 * - New: showSudoModal(), hideSudoModal(), verifySudoAndInstall(), launchBothProcesses()
 * - Cockpit panel install runs as a separate detached process (start-cockpit-install dispatch)
 * - New: pollCockpitInstall(), updateCockpitInstallStatus() — polls cockpit-install-progress
 * - showFinishedState() shows both container update result and cockpit install result
 * - state extended: sudoPassword, cockpitInstallState, cockpitInstallExitCode, cockpitLogOffset
 *
 * Changes in v1.3.0:
 * - checkForUpdates now calls list-releases dispatch and populates a selectable releases list panel
 * - New renderReleasesList(), autoSelectRecommended(), onReleaseSelected(), findRelease()
 * - downloadUpdate passes --version <selectedVersion> to dispatch
 * - refreshUI handles both list-based and single-version (persisted) state
 * - Beta checkbox change clears releases list and selected version
 *
 * Changes in v1.2.1:
 * - Beta checkbox change handler: reset stale update state (available/downloaded/latestVersion)
 *   and call refreshUI() so Download/Install are disabled until user re-checks with new preference
 *
 * Changes in v1.2.0:
 * - Removed superuser:'try' from start-update spawn (rootless podman requires user context)
 * - Beta checkbox: reads includeBeta from updates.json, sends --include-prerelease to check-updates
 * - Persist beta preference via set-include-beta dispatch command
 *
 * Changes in v1.1.0:
 * - Install uses start-update (detached) + update-progress polling; reconnectable UI
 * - State machine: IDLE, INSTALLING, FINISHED_SUCCESS, FINISHED_FAILED
 * - init() calls update-progress before read-status to detect running update
 * - Compatibility check: disable install when compatible === false
 * - Dismiss button calls cleanup-update and returns to IDLE
 *
 * Changes in v1.0.1:
 * - Strip ANSI escape codes in appendOutput(); loadStatus() in runOperation catch
 */

(function () {
  'use strict';

  /* =====================================================================
   * Theme sync — inherit Cockpit shell dark/light theme
   * ===================================================================== */

  function isDarkColor(colorStr) {
    if (!colorStr) return false;
    var m = colorStr.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
    if (!m) return false;
    var r = parseInt(m[1], 10) / 255;
    var g = parseInt(m[2], 10) / 255;
    var b = parseInt(m[3], 10) / 255;
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return lum < 0.4;
  }

  function applyTheme() {
    try {
      var parentBody = window.parent.document.body;
      if (!parentBody) return;
      var bg = window.parent.getComputedStyle(parentBody).backgroundColor;
      document.documentElement.classList.toggle('theme-dark', isDarkColor(bg));
    } catch (e) {
      /* parent not accessible */
    }
  }

  function syncTheme() {
    requestAnimationFrame(function () {
      applyTheme();
    });
  }

  applyTheme();

  try {
    var parentDoc = window.parent.document;
    var themeObs = new MutationObserver(syncTheme);
    themeObs.observe(parentDoc.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });
    themeObs.observe(parentDoc.body, { attributes: true, attributeFilter: ['class', 'style'] });
  } catch (e) {
    /* parent not accessible */
  }

  /* =====================================================================
   * Constants
   * ===================================================================== */

  var DISPATCH_PATH = '/usr/local/share/cockpit/app-admin/update-dispatch.sh';
  var POLL_INTERVAL_MS = 2000;

  /* =====================================================================
   * DOM references
   * ===================================================================== */

  var els = {};

  /* =====================================================================
   * State
   * ===================================================================== */

  var state = {
    uiState: 'IDLE',           // IDLE | INSTALLING | FINISHED_SUCCESS | FINISHED_FAILED
    operationRunning: false,
    currentProcess: null,
    updateData: null,          // from updates.json (persisted state)
    pollTimer: null,
    logOffset: 0,
    installExitCode: null,
    includeBeta: false,
    releasesList: [],          // array of release objects from list-releases
    selectedVersion: null,     // version string selected by user in the list
    confirmedInstallVersion: '', // staged version shown in the sudo modal for this install
    sudoPassword: null,        // held in memory only until start-update reads it
    githubTokenConfigured: false
  };

  var outputRawText = '';

  /* =====================================================================
   * Update status display — read updates.json and refresh UI
   * ===================================================================== */

  function loadStatus() {
    var proc = cockpit.spawn([DISPATCH_PATH, 'read-status'], {
      err: 'out'
    });

    proc.then(function (data) {
      try {
        state.updateData = JSON.parse(data);
        state.includeBeta = !!(state.updateData && state.updateData.includeBeta === true);
        if (els.chkBeta) {
          els.chkBeta.checked = state.includeBeta;
        }
      } catch (e) {
        state.updateData = null;
      }
      refreshUI();
    });

    proc.catch(function () {
      state.updateData = null;
      refreshUI();
    });
  }

  function formatInstalledVersion(version) {
    if (!version || version === 'unknown') {
      return '—';
    }
    return version;
  }

  function formatDownloadedVersion(version) {
    if (!version) {
      return '—';
    }
    return version;
  }

  function panelActions() {
    var d = state.updateData;
    var hasList = !!(state.releasesList && state.releasesList.length > 0);
    var selectedRelease = state.selectedVersion ? findRelease(state.selectedVersion) : null;
    return updatePanelActions({
      stagedVersion: d && d.stagedVersion,
      latestVersion: d && d.latestVersion,
      stagedCompatible: d ? d.compatible : true,
      selectedVersion: state.selectedVersion,
      selectedCompatible: selectedRelease ? selectedRelease.compatible : true,
      hasList: hasList,
      busy: state.operationRunning === true
        || state.uiState === 'INSTALLING'
    });
  }

  function formatTimestamp(ts) {
    if (!ts) return '—';
    try {
      var d = new Date(ts);
      if (isNaN(d.getTime())) return ts;
      return d.toLocaleString();
    } catch (e) {
      return ts;
    }
  }

  function refreshUI() {
    var d = state.updateData;
    var hasList = !!(state.releasesList && state.releasesList.length > 0);

    /* --- Version card --- */
    if (!d) {
      els.currentVersion.textContent = '—';
      if (els.downloadedVersion) els.downloadedVersion.textContent = '—';
      els.latestVersion.textContent = '—';
    } else {
      els.currentVersion.textContent = formatInstalledVersion(d.currentVersion);
      if (els.downloadedVersion) {
        els.downloadedVersion.textContent = formatDownloadedVersion(d.stagedVersion);
      }
      els.latestVersion.textContent = formatInstalledVersion(d.latestVersion);
    }
    if (els.installedDate) els.installedDate.textContent = formatTimestamp(d && d.deployedAt);
    if (els.lastUpdatedDate) els.lastUpdatedDate.textContent = formatTimestamp(d && d.lastUpdatedAt);
    els.lastCheck.textContent = d && d.lastCheck ? formatTimestamp(d.lastCheck) : 'never';

    /* Version numbers stay live during install. Keep the installing or finished badge
       only while installing, or after finish when there is no staged kit and no releases list. */
    var actions = panelActions();
    var stagedVersion = (d && typeof d.stagedVersion === 'string') ? d.stagedVersion : '';
    var finishedState = state.uiState === 'FINISHED_SUCCESS' || state.uiState === 'FINISHED_FAILED';
    var inInstallFlow = state.uiState === 'INSTALLING'
      || (finishedState && !hasList && !stagedVersion);

    if (!inInstallFlow) {
      var isUpToDate = !!(d && d.currentVersion && d.latestVersion
        && d.currentVersion !== 'unknown'
        && d.currentVersion === d.latestVersion);

      if (stagedVersion && d.compatible === false) {
        setBadge('warning', 'update available');
        setCompatibilityWarning(true);
      } else if (stagedVersion) {
        setBadge('info', 'ready to install');
        setCompatibilityWarning(false);
      } else if (hasList) {
        setBadge('warning', state.releasesList.length + ' update(s) available');
        setCompatibilityWarning(false);
      } else if (d && d.available && !isUpToDate) {
        setBadge('warning', 'update available');
        setCompatibilityWarning(false);
      } else if (d) {
        setBadge('success', 'up to date');
        setCompatibilityWarning(false);
      } else {
        setBadge('neutral', 'unknown');
        setCompatibilityWarning(false);
      }

      if (!hasList) {
        if (actions.showFallbackNotes && d && ((d.available && !isUpToDate) || stagedVersion)) {
          showReleaseNotes(d.releaseNotes);
        } else {
          hideReleaseNotes();
        }
      }
    }

    els.btnDownload.disabled = !actions.downloadEnabled;
    els.btnInstall.disabled = !actions.installEnabled;
    els.btnInstall.textContent = actions.installLabel;
    if (els.btnDeleteDownload) {
      els.btnDeleteDownload.disabled = !actions.deleteEnabled;
      els.btnDeleteDownload.textContent = actions.deleteLabel;
    }

    els.btnCheck.disabled = !actions.checkEnabled;
    els.btnCheck.textContent = actions.checkLabel;
  }

  function setBadge(type, text) {
    els.statusBadge.textContent = text;
    els.statusBadge.className = 'update-badge update-badge-' + type;
  }

  function setCompatibilityWarning(show) {
    if (!els.compatibilityWarning) return;
    if (show) {
      els.compatibilityWarning.classList.remove('hidden');
    } else {
      els.compatibilityWarning.classList.add('hidden');
    }
  }

  function showReleaseNotes(notes) {
    if (!els.releaseNotesWrapper || !els.releaseNotes) return;
    if (!notes || notes === '...') {
      els.releaseNotes.textContent = 'No additional notes for this release.';
      els.releaseNotesWrapper.classList.remove('hidden');
      return;
    }
    var decoded = notes.replace(/\\n/g, '\n');
    els.releaseNotes.textContent = decoded;
    els.releaseNotesWrapper.classList.remove('hidden');
  }

  function hideReleaseNotes() {
    els.releaseNotesWrapper.classList.add('hidden');
    els.releaseNotes.textContent = '';
  }

  /* =====================================================================
   * Releases list — render, select, auto-recommend
   * ===================================================================== */

  function findRelease(version) {
    if (!state.releasesList) return null;
    for (var i = 0; i < state.releasesList.length; i++) {
      if (state.releasesList[i].version === version) return state.releasesList[i];
    }
    return null;
  }

  function renderReleasesList() {
    var list = state.releasesList;
    if (!list || list.length === 0) {
      hideReleasesList();
      return;
    }

    var recommendedVersion = findRecommendedVersion();

    var html = '';
    for (var i = 0; i < list.length; i++) {
      var rel = list[i];
      var classes = 'update-release-item';
      if (!rel.compatible) classes += ' incompatible';
      if (rel.version === recommendedVersion) classes += ' recommended';

      var compatBadge = '';
      if (rel.compatible) {
        compatBadge = '<span class="update-release-badge update-release-badge-ok">compatible</span>';
      } else {
        var reqLabel = rel.minVersion ? 'requires ' + escapeHtml(rel.minVersion) : 'incompatible';
        compatBadge = '<span class="update-release-badge update-release-badge-warn">' + reqLabel + '</span>';
      }

      var extraBadges = '';
      if (rel.prerelease) {
        extraBadges += ' <span class="update-release-badge update-release-badge-beta">beta</span>';
      }
      if (rel.version === recommendedVersion) {
        extraBadges += ' <span class="update-release-badge update-release-badge-recommended">recommended</span>';
      }

      html += '<label class="' + classes + '">'
        + '<input type="radio" name="release-version" value="' + escapeHtml(rel.version) + '"'
        + ' class="update-release-radio"'
        + (rel.compatible ? '' : ' disabled')
        + '>'
        + '<span class="update-release-version">' + escapeHtml(rel.version) + '</span>'
        + '<span class="update-release-min">min: ' + escapeHtml(rel.minVersion || '—') + '</span>'
        + compatBadge
        + extraBadges
        + '</label>';
    }

    els.releasesList.innerHTML = html;
    els.releasesWrapper.classList.remove('hidden');

    var radios = els.releasesList.querySelectorAll('input[name="release-version"]');
    for (var j = 0; j < radios.length; j++) {
      radios[j].addEventListener('change', onReleaseSelected);
    }
  }

  function findRecommendedVersion() {
    var list = state.releasesList;
    if (!list || list.length === 0) return null;
    for (var i = 0; i < list.length; i++) {
      if (list[i].compatible) return list[i].version;
    }
    return null;
  }

  function autoSelectRecommended() {
    var recommended = findRecommendedVersion();
    if (!recommended) return;

    state.selectedVersion = recommended;

    var radio = els.releasesList.querySelector('input[value="' + recommended + '"]');
    if (radio) {
      radio.checked = true;
      var item = radio.closest('.update-release-item');
      if (item) item.classList.add('selected');
    }

    var rel = findRelease(recommended);
    showReleaseNotes(rel ? rel.releaseNotes : '');

    refreshUI();
  }

  function onReleaseSelected(e) {
    state.selectedVersion = e.target.value;

    var items = els.releasesList.querySelectorAll('.update-release-item');
    for (var i = 0; i < items.length; i++) {
      items[i].classList.remove('selected');
    }
    var item = e.target.closest('.update-release-item');
    if (item) item.classList.add('selected');

    var rel = findRelease(state.selectedVersion);
    showReleaseNotes(rel ? rel.releaseNotes : '');
    refreshUI();
  }

  function hideReleasesList() {
    if (els.releasesWrapper) {
      els.releasesWrapper.classList.add('hidden');
    }
    if (els.releasesList) {
      els.releasesList.innerHTML = '';
    }
  }

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  /* =====================================================================
   * Polling for update progress (detached install)
   * ===================================================================== */

  function stopPolling() {
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function parseProgressJson(data) {
    try {
      return JSON.parse(data);
    } catch (e) {
      return { status: 'idle' };
    }
  }

  // Last JSON object in a cockpit spawn buffer. The stream callback receives
  // the script output; the promise body is empty once a stream callback is set.
  function parseLastJsonObject(text) {
    if (text == null) return null;
    var raw = String(text);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch (e) {
      var start = raw.lastIndexOf('{');
      if (start < 0) return null;
      try {
        return JSON.parse(raw.slice(start));
      } catch (e2) {
        return null;
      }
    }
  }

  function parseSpawnResult(streamed, resolved) {
    var fromStream = parseLastJsonObject(streamed);
    if (fromStream && typeof fromStream === 'object') return fromStream;
    var fromResolved = parseLastJsonObject(resolved);
    if (fromResolved && typeof fromResolved === 'object') return fromResolved;
    return { status: 'idle' };
  }

  function spawnFailureDetail(output, ex) {
    var parsed = null;
    if (output) {
      try {
        var text = String(output);
        var start = text.lastIndexOf('{');
        parsed = JSON.parse(start >= 0 ? text.slice(start) : text);
      } catch (e) {
        parsed = null;
      }
    }
    if (parsed && typeof parsed.error === 'string' && parsed.error) {
      return parsed.error;
    }
    if (ex && ex.message) {
      return ex.message;
    }
    if (ex && ex.exit_status) {
      return 'Exit code: ' + ex.exit_status + '.';
    }
    return 'unknown error';
  }

  function unescapeLogContent(str) {
    if (!str) return '';
    return str
      .replace(/\\n/g, '\n')
      .replace(/\\r/g, '\r')
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, '\\');
  }

  function pollProgress() {
    if (state.uiState !== 'INSTALLING') return;

    var proc = cockpit.spawn([DISPATCH_PATH, 'update-progress', String(state.logOffset)], {
      err: 'out'
    });

    proc.then(function (data) {
      var payload = parseProgressJson(data);
      if (payload.logContent) {
        var chunk = unescapeLogContent(payload.logContent);
        if (chunk) {
          showOutput();
          appendOutput(chunk);
        }
      }
      if (payload.logOffset !== undefined) {
        state.logOffset = payload.logOffset;
      }

      if (payload.status === 'finished') {
        stopPolling();
        hideProgress();
        state.installExitCode = payload.exitCode !== undefined ? payload.exitCode : 1;
        state.uiState = (state.installExitCode === 0) ? 'FINISHED_SUCCESS' : 'FINISHED_FAILED';
        showFinishedState();
        if (state.installExitCode === 0) {
          state.releasesList = [];
          state.selectedVersion = null;
          hideReleasesList();
          hideReleaseNotes();
        }
        loadStatus();
      } else if (payload.status === 'running') {
        state.pollTimer = setTimeout(pollProgress, POLL_INTERVAL_MS);
      } else {
        stopPolling();
        state.uiState = 'IDLE';
        hideProgress();
        loadStatus();
      }
    });

    proc.catch(function () {
      state.pollTimer = setTimeout(pollProgress, POLL_INTERVAL_MS);
    });
  }

  function showFinishedState() {
    hideProgress();
    showOutput();
    if (state.uiState === 'FINISHED_SUCCESS') {
      setBadge('success', 'update installed');
      showStatus('success', 'Update installed successfully. Services have been restarted.');
    } else {
      setBadge('active', 'update failed');
      showStatus('error', 'Update failed. Exit code: ' + state.installExitCode + '. Check output below.');
    }
  }

  /* =====================================================================
   * Operations — check (list-releases), download, install (start-update + polling)
   * ===================================================================== */

  function resetFinishedState() {
    if (state.uiState !== 'FINISHED_SUCCESS' && state.uiState !== 'FINISHED_FAILED') {
      return;
    }
    state.uiState = 'IDLE';
    state.installExitCode = null;
    hideStatus();
    cockpit.spawn([DISPATCH_PATH, 'cleanup-update'], { err: 'out' }).catch(function () {});
  }

  function runOperationWithArgs(cmdArgs, statusMessage, onSuccess) {
    if (state.operationRunning) return;

    state.operationRunning = true;
    refreshUI();
    clearOutput();
    showOutput();
    showStatus('running', statusMessage);
    showProgress();

    var spawnArgs = [DISPATCH_PATH].concat(cmdArgs);
    var proc = cockpit.spawn(spawnArgs, {
      err: 'out'
    });

    state.currentProcess = proc;

    proc.stream(function (data) {
      appendOutput(data);
    });

    proc.then(function () {
      state.operationRunning = false;
      state.currentProcess = null;
      hideProgress();
      if (onSuccess) {
        onSuccess();
      }
      loadStatus();
    });

    proc.catch(function (ex) {
      state.operationRunning = false;
      state.currentProcess = null;
      hideProgress();
      var msg = 'Operation failed.';
      if (ex.exit_status) {
        msg += ' Exit code: ' + ex.exit_status + '.';
      }
      if (ex.message) {
        msg += ' ' + ex.message;
      }
      showStatus('error', msg);
      refreshUI();
      loadStatus();
    });
  }

  function checkForUpdates() {
    if (state.operationRunning || state.uiState === 'INSTALLING') return;
    resetFinishedState();
    loadGithubTokenStatus();

    state.operationRunning = true;
    state.releasesList = [];
    state.selectedVersion = null;
    hideReleasesList();
    hideReleaseNotes();
    hideStatus();
    refreshUI();
    showProgress();

    var cmd = [DISPATCH_PATH, 'list-releases'];
    if (state.includeBeta) {
      cmd.push('--include-prerelease');
    }

    var proc = cockpit.spawn(cmd);

    proc.then(function (data) {
      state.operationRunning = false;
      hideProgress();

      try {
        var result = JSON.parse(data);

        if (result.error) {
          showStatus('error', 'Update check failed: ' + result.error);
          loadStatus();
          return;
        }

        state.releasesList = result.releases || [];

        /* Update state.updateData from the response so version card refreshes */
        if (!state.updateData) state.updateData = {};
        state.updateData.currentVersion = result.currentVersion;
        state.updateData.lastCheck = result.lastCheck;
        if (state.releasesList.length > 0) {
          state.updateData.latestVersion = state.releasesList[0].version;
          state.updateData.available = true;
        } else {
          state.updateData.available = false;
        }

        renderReleasesList();
        autoSelectRecommended();
        refreshUI();

        if (state.releasesList.length > 0) {
          showStatus('success', state.releasesList.length + ' update(s) found.');
        } else if (state.updateData && state.updateData.stagedVersion && state.updateData.compatible !== false) {
          showStatus('success', 'No newer releases in this check. Downloaded update v' + state.updateData.stagedVersion + ' is still ready to install.');
        } else {
          showStatus('success', 'No updates available. You are up to date.');
        }
        loadStatus();
      } catch (e) {
        showStatus('error', 'Failed to parse update check result.');
        loadStatus();
      }
    });

    proc.catch(function (ex) {
      state.operationRunning = false;
      hideProgress();
      showStatus('error', 'Update check failed: ' + (ex.message || 'unknown error'));
      loadStatus();
    });
  }

  function downloadUpdate() {
    if (!state.selectedVersion || state.operationRunning || state.uiState === 'INSTALLING') return;
    resetFinishedState();

    var version = state.selectedVersion;
    runOperationWithArgs(
      ['download-update', '--version', version],
      'Downloading update v' + version + '...',
      function () {
        showStatus('success', 'Update v' + version + ' downloaded. Ready to install.');
      }
    );
  }

  function deleteDownload() {
    if (state.operationRunning || state.uiState === 'INSTALLING') {
      return;
    }
    resetFinishedState();

    var staged = (state.updateData && typeof state.updateData.stagedVersion === 'string')
      ? state.updateData.stagedVersion
      : '';
    if (!staged) return;

    var confirmed = window.confirm(
      'Delete downloaded update v' + staged + '? The installed application is not removed.'
    );
    if (!confirmed) return;

    var proc = cockpit.spawn([DISPATCH_PATH, 'discard-download'], {
      err: 'out'
    });
    var output = '';
    proc.stream(function (chunk) {
      output += chunk;
    });

    proc.then(function () {
      showStatus('success', 'Downloaded update v' + staged + ' deleted.');
      loadStatus();
    });

    proc.catch(function (ex) {
      showStatus('error', 'Could not delete the downloaded update. ' + spawnFailureDetail(output, ex));
    });
  }

  /* =====================================================================
   * Sudo password modal
   * ===================================================================== */

  function ensureUpdateDialogPortaled(el) {
    if (el && el.parentNode !== document.body) {
      document.body.appendChild(el);
    }
  }

  function showSudoModal(stagedVersion) {
    var modal = document.getElementById('sudo-modal');
    var input = document.getElementById('sudo-password-input');
    var errEl = document.getElementById('sudo-error');
    var versionEl = document.getElementById('sudo-install-version');
    if (!modal) return;
    state.confirmedInstallVersion = stagedVersion || '';
    ensureUpdateDialogPortaled(modal);
    if (errEl) errEl.classList.add('hidden');
    if (input) input.value = '';
    if (versionEl) versionEl.textContent = state.confirmedInstallVersion;
    modal.classList.remove('hidden');
    if (input) setTimeout(function () { input.focus(); }, 50);
  }

  function hideSudoModal() {
    var modal = document.getElementById('sudo-modal');
    if (modal) modal.classList.add('hidden');
  }

  function verifySudoAndInstall() {
    var input = document.getElementById('sudo-password-input');
    var errEl = document.getElementById('sudo-error');
    var confirmBtn = document.getElementById('btn-sudo-confirm');
    var password = input ? input.value : '';

    if (!password) {
      if (errEl) { errEl.textContent = 'Password cannot be empty.'; errEl.classList.remove('hidden'); }
      return;
    }

    if (confirmBtn) confirmBtn.disabled = true;
    if (errEl) errEl.classList.add('hidden');

    var proc = cockpit.spawn([DISPATCH_PATH, 'verify-sudo'], { err: 'out' });
    proc.input(password + '\n');

    proc.then(function (data) {
      if (confirmBtn) confirmBtn.disabled = false;
      var result = {};
      try { result = JSON.parse(data); } catch (e) { result = { status: 'fail' }; }

      if (result.status === 'ok') {
        state.sudoPassword = password;
        hideSudoModal();
        launchInstallProcess();
      } else {
        if (errEl) { errEl.textContent = 'Incorrect password. Please try again.'; errEl.classList.remove('hidden'); }
        if (input) { input.value = ''; input.focus(); }
      }
    });

    proc.catch(function () {
      if (confirmBtn) confirmBtn.disabled = false;
      if (errEl) { errEl.textContent = 'Failed to verify password. Please try again.'; errEl.classList.remove('hidden'); }
    });
  }

  function launchInstallProcess() {
    var stagedVersion = state.confirmedInstallVersion || '';
    if (!stagedVersion) {
      showStatus('error', 'No downloaded update to install.');
      loadStatus();
      return;
    }

    state.uiState = 'INSTALLING';
    setBadge('active', 'installing...');
    clearOutput();
    showOutput();
    showStatus('running', 'Installing update v' + stagedVersion + '... You can navigate away — the update will continue in the background.');
    showProgress();
    setOutput('Starting update...\n');
    state.logOffset = 0;
    refreshUI();

    // One install process for the staged kit confirmed in the modal.
    // The first phase reads the sudo password from stdin, then it is dropped.
    var proc = cockpit.spawn([DISPATCH_PATH, 'start-update', stagedVersion], {
      err: 'out'
    });
    if (state.sudoPassword) {
      proc.input(state.sudoPassword + '\n');
      state.sudoPassword = null;
    }
    var output = '';
    proc.stream(function (chunk) {
      output += chunk;
    });

    proc.then(function (data) {
      var payload = parseSpawnResult(output, data);
      if (payload.status === 'already_running' || payload.status === 'started') {
        state.uiState = 'INSTALLING';
        state.logOffset = 0;
        showOutput();
        showProgress();
        pollProgress();
        return;
      }
      state.uiState = 'IDLE';
      state.sudoPassword = null;
      hideProgress();
      var detail = payload.error || payload.message;
      if (!detail) {
        if (payload.status === 'mismatch') {
          detail = 'the staged update does not match the version just confirmed';
        } else if (payload.status) {
          detail = 'status ' + payload.status;
        } else {
          detail = 'the update did not start';
        }
      }
      showStatus('error', 'Failed to start update: ' + detail);
      loadStatus();
    });

    proc.catch(function (ex) {
      state.uiState = 'IDLE';
      state.sudoPassword = null;
      hideProgress();
      showStatus('error', 'Failed to start update: ' + spawnFailureDetail(output, ex));
      loadStatus();
    });
  }

  function installUpdate() {
    if (state.operationRunning || state.uiState === 'INSTALLING') return;

    resetFinishedState();
    refreshUI();

    var proc = cockpit.spawn([DISPATCH_PATH, 'read-status'], {
      err: 'out'
    });

    proc.then(function (data) {
      var status;
      try {
        status = JSON.parse(data);
      } catch (e) {
        showStatus('error', 'Could not read update status.');
        return;
      }

      state.updateData = status;
      refreshUI();

      var stagedVersion = (typeof status.stagedVersion === 'string') ? status.stagedVersion : '';
      if (!stagedVersion) {
        showStatus('error', 'No downloaded update to install.');
        return;
      }

      if (status.compatible === false) {
        window.alert('This update cannot be installed directly from your current version. Please update to at least ' + (status.minVersion || 'the required version') + ' first.');
        return;
      }

      showSudoModal(stagedVersion);
    });

    proc.catch(function (ex) {
      var msg = 'Could not read update status.';
      if (ex && ex.message) {
        msg += ' ' + ex.message;
      }
      showStatus('error', msg);
    });
  }

  /* =====================================================================
   * UI helpers
   * ===================================================================== */

  function showStatus(type, message) {
    els.operationStatus.textContent = message;
    els.operationStatus.className = 'update-status status-' + type;
    els.operationStatus.classList.remove('hidden');
  }

  function hideStatus() {
    els.operationStatus.classList.add('hidden');
    els.operationStatus.className = 'update-status hidden';
  }

  function showOutput() {
    els.outputWrapper.classList.remove('hidden');
  }

  function stripAnsi(str) {
    return str.replace(/\x1b\[[0-9;]*m/g, '');
  }

  function formatLogHtml(rawText) {
    var cleaned = stripAnsi(rawText);
    var lines = cleaned.split('\n');
    var formatted = [];
    var i;
    for (i = 0; i < lines.length; i++) {
      var line = escapeHtml(lines[i]);
      var phaseMatch = line.match(/^&gt;&gt; (phase [0-9]+\/[0-9]+)\s+(.*)$/);
      if (phaseMatch) {
        line = '<span class="update-log-phase"><span class="update-log-phase-num">&gt;&gt; '
          + phaseMatch[1]
          + '</span>  <span class="update-log-phase-title">'
          + phaseMatch[2]
          + '</span></span>';
      } else if (/^─{10,}$/.test(line)) {
        line = '<span class="update-log-rule">' + line + '</span>';
      } else if (/^.*===\s+.*\s+===.*$/.test(line)) {
        line = '<span class="update-log-banner">' + line + '</span>';
      }
      line = line.replace(/\[✓\]/g, '<span class="update-log-ok">[✓]</span>');
      line = line.replace(/\[✗\]/g, '<span class="update-log-fail">[✗]</span>');
      line = line.replace(/\[!\]/g, '<span class="update-log-warn">[!]</span>');
      formatted.push(line);
    }
    return formatted.join('\n');
  }

  function setOutput(text) {
    outputRawText = stripAnsi(text);
    els.output.innerHTML = formatLogHtml(outputRawText);
  }

  function appendOutput(text) {
    outputRawText += stripAnsi(text);
    els.output.innerHTML = formatLogHtml(outputRawText);
    els.output.scrollTop = els.output.scrollHeight;
  }

  function clearOutput() {
    outputRawText = '';
    els.output.innerHTML = '';
    els.outputWrapper.classList.add('hidden');
    hideStatus();
    hideProgress();
  }

  function showProgress() {
    els.progressWrapper.classList.remove('hidden');
    els.progressFill.classList.add('update-progress-indeterminate');
    els.progressText.textContent = 'Working...';
  }

  function hideProgress() {
    els.progressWrapper.classList.add('hidden');
    els.progressFill.classList.remove('update-progress-indeterminate');
  }

  /* =====================================================================
   * GitHub access key — status badge and save (token never stored on state)
   * ===================================================================== */

  function updateGithubTokenBadge() {
    if (!els.githubTokenBadge) return;
    if (state.githubTokenConfigured) {
      els.githubTokenBadge.textContent = 'Key saved';
      els.githubTokenBadge.className = 'update-badge update-badge-success';
    } else {
      els.githubTokenBadge.textContent = 'Key not set';
      els.githubTokenBadge.className = 'update-badge update-badge-neutral';
    }
  }

  function showGithubTokenMsg(kind, text) {
    if (!els.githubTokenMsg) return;
    els.githubTokenMsg.textContent = text;
    els.githubTokenMsg.className = 'update-github-msg update-github-msg-' + kind;
  }

  function loadGithubTokenStatus() {
    var proc = cockpit.spawn([DISPATCH_PATH, 'github-token-status'], {
      err: 'out'
    });

    proc.then(function (data) {
      try {
        var result = JSON.parse(data);
        state.githubTokenConfigured = result.configured === true;
      } catch (e) {
        state.githubTokenConfigured = false;
      }
      updateGithubTokenBadge();
    });

    proc.catch(function () {
      state.githubTokenConfigured = false;
      updateGithubTokenBadge();
    });
  }

  function saveGithubToken() {
    if (!els.githubTokenInput) return;

    var token = (els.githubTokenInput.value || '').trim();
    if (!token) {
      showGithubTokenMsg('error', 'Paste a key before saving.');
      return;
    }

    var proc = cockpit.spawn([DISPATCH_PATH, 'set-github-token'], { err: 'out' });
    proc.input(token + '\n');
    els.githubTokenInput.value = '';

    proc.then(function (data) {
      var result = {};
      try {
        var text = (data || '').toString();
        var start = text.lastIndexOf('{');
        result = JSON.parse(start >= 0 ? text.slice(start) : text);
      } catch (e) {
        showGithubTokenMsg('error', 'Could not save the key.');
        return;
      }

      if (result.status === 'ok') {
        state.githubTokenConfigured = true;
        updateGithubTokenBadge();
        var extras = [];
        if (result.ghcrLogin === 'failed') {
          extras.push('image registry login did not finish');
        }
        if (result.workerRestart === 'failed') {
          extras.push('worker restart did not finish');
        }
        if (extras.length) {
          showGithubTokenMsg('warning', 'Key saved. Warning: ' + extras.join('; ') + '.');
        } else {
          showGithubTokenMsg('success', 'Key saved.');
        }
      } else {
        showGithubTokenMsg('error', 'Could not save the key.');
      }
    });

    proc.catch(function () {
      showGithubTokenMsg('error', 'Could not save the key.');
    });
  }

  function refreshSystemState() {
    loadStatus();
    loadGithubTokenStatus();
  }

  function isUpdatesSectionVisible() {
    var sec = document.getElementById('section-updates');
    return !!(sec && !sec.classList.contains('hidden'));
  }

  function refreshSystemStateOnFocus() {
    if (document.visibilityState === 'visible'
        && isUpdatesSectionVisible()
        && !state.operationRunning
        && state.uiState !== 'INSTALLING') {
      refreshSystemState();
    }
  }

  /* =====================================================================
   * Initialization — check update-progress first (reconnect)
   * ===================================================================== */

  function init() {
    els.currentVersion = document.getElementById('current-version');
    els.downloadedVersion = document.getElementById('downloaded-version');
    els.latestVersion = document.getElementById('latest-version');
    els.installedDate = document.getElementById('installed-date');
    els.lastUpdatedDate = document.getElementById('last-updated-date');
    els.lastCheck = document.getElementById('last-check');
    els.statusBadge = document.getElementById('update-status-badge');
    els.btnCheck = document.getElementById('btn-check');
    els.btnDownload = document.getElementById('btn-download');
    els.btnDeleteDownload = document.getElementById('btn-delete-download');
    els.btnInstall = document.getElementById('btn-install');
    els.btnClear = document.getElementById('btn-clear');
    els.operationStatus = document.getElementById('operation-status');
    els.progressWrapper = document.getElementById('progress-wrapper');
    els.progressFill = document.getElementById('progress-fill');
    els.progressText = document.getElementById('progress-text');
    els.outputWrapper = document.getElementById('output-wrapper');
    els.output = document.getElementById('output');
    els.releaseNotesWrapper = document.getElementById('release-notes-wrapper');
    els.releaseNotes = document.getElementById('release-notes');
    els.compatibilityWarning = document.getElementById('compatibility-warning');
    els.chkBeta = document.getElementById('chk-beta');
    els.releasesWrapper = document.getElementById('releases-list-wrapper');
    els.releasesList = document.getElementById('releases-list');
    els.githubTokenBadge = document.getElementById('github-token-badge');
    els.githubTokenInput = document.getElementById('github-token-input');
    els.btnGithubTokenSave = document.getElementById('btn-github-token-save');
    els.githubTokenMsg = document.getElementById('github-token-msg');

    els.btnCheck.addEventListener('click', checkForUpdates);
    els.btnDownload.addEventListener('click', downloadUpdate);
    if (els.btnDeleteDownload) {
      els.btnDeleteDownload.addEventListener('click', deleteDownload);
    }
    els.btnInstall.addEventListener('click', installUpdate);
    document.addEventListener('updates-panel-show', function () {
      refreshSystemState();
    });
    window.addEventListener('focus', refreshSystemStateOnFocus);
    document.addEventListener('visibilitychange', refreshSystemStateOnFocus);
    els.btnClear.addEventListener('click', function () {
      resetFinishedState();
      clearOutput();
      refreshUI();
    });

    // Sudo modal buttons
    var btnSudoCancel = document.getElementById('btn-sudo-cancel');
    var btnSudoConfirm = document.getElementById('btn-sudo-confirm');
    var sudoInput = document.getElementById('sudo-password-input');
    if (btnSudoCancel) {
      btnSudoCancel.addEventListener('click', hideSudoModal);
    }
    if (btnSudoConfirm) {
      btnSudoConfirm.addEventListener('click', verifySudoAndInstall);
    }
    if (sudoInput) {
      sudoInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') verifySudoAndInstall();
        if (e.key === 'Escape') hideSudoModal();
      });
    }
    if (els.btnGithubTokenSave) {
      els.btnGithubTokenSave.addEventListener('click', saveGithubToken);
    }
    if (els.githubTokenInput) {
      els.githubTokenInput.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          saveGithubToken();
        }
      });
    }
    loadGithubTokenStatus();
    if (els.chkBeta) {
      els.chkBeta.addEventListener('change', function () {
        state.includeBeta = els.chkBeta.checked;
        state.releasesList = [];
        state.selectedVersion = null;
        hideReleasesList();
        hideReleaseNotes();
        refreshUI();

        var betaProc = cockpit.spawn([DISPATCH_PATH, 'set-include-beta', state.includeBeta ? 'true' : 'false'], {
          err: 'out'
        });

        betaProc.then(function () {
          loadStatus();
        });

        betaProc.catch(function (ex) {
          var msg = 'Could not save the beta setting.';
          if (ex && ex.message) {
            msg += ' ' + ex.message;
          }
          showStatus('error', msg);
          loadStatus();
        });
      });
    }

    var progressProc = cockpit.spawn([DISPATCH_PATH, 'update-progress', '0'], {
      err: 'out'
    });

    progressProc.then(function (data) {
      var payload = parseProgressJson(data);
      if (payload.status === 'running') {
        state.uiState = 'INSTALLING';
        setBadge('active', 'installing...');
        clearOutput();
        showOutput();
        showStatus('running', 'Update in progress. You can navigate away — the update will continue in the background.');
        showProgress();
        setOutput('Reconnecting to update output...\n');
        state.logOffset = 0;
        refreshUI();
        pollProgress();
      } else if (payload.status === 'finished') {
        state.installExitCode = payload.exitCode !== undefined ? payload.exitCode : 1;
        state.uiState = (state.installExitCode === 0) ? 'FINISHED_SUCCESS' : 'FINISHED_FAILED';
        clearOutput();
        if (payload.logContent) {
          appendOutput(unescapeLogContent(payload.logContent));
        }
        if (payload.logOffset !== undefined) {
          state.logOffset = payload.logOffset;
        }
        showFinishedState();
        loadStatus();
      } else {
        state.uiState = 'IDLE';
        loadStatus();
      }
    });

    progressProc.catch(function () {
      state.uiState = 'IDLE';
      loadStatus();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
