/* Version: 0.28.9
 * Purpose: Main logic for application admin tools Cockpit package.
 * Handles navigation between sections, backup form interactions, and command execution
 * via Cockpit API (cockpit.spawn). Each admin function calls scripts through the
 * admin-dispatch.sh dispatcher that resolves paths to deployment scripts.
 * Cockpit package; filename: admin.js
 *
 * Changes in v0.28.9:
 * - Panel version constant is v0.28.9.
 * - Disk Status renders one donut card per mounted disk, storage placement controls, and space cleanup actions.
 * - Container memory limits use a 10%–80% scale. CPU limit controls are removed.
 * - State memory that is empty or a legacy size (256m, 512m, 1g, 2g, 4g, 8g) displays as 10% without a spurious diff.
 *
 * Changes in v0.26.3:
 * - Panel version constant is v0.26.3.
 *
 * Changes in v0.26.2:
 * - De-brand runtime paths, filenames, and user-visible product name to application/app.
 * - Container Environment and password reset use APP_* keys. Panel version constant is ADMIN_TOOLS_VERSION.
 * - Dispatch path is /usr/local/share/cockpit/app-admin/admin-dispatch.sh. The header badge id is admin-version.
 * 
 * Changes in v0.25.4:
 * - Container Environment load error names app.env.
 * - Panel version constant is v0.25.4.
 *
 * Changes in v0.25.2:
 * - Backup progress uses 13 base steps (includes state volume export) and expects 7 core images.
 * - Estimate summary lists File storage (fs_data) and State store (state_data).
 * - Panel version constant is v0.25.2.
 *
 * Changes in v0.24.5:
 * - Opening Updates dispatches updates-panel-show so the panel re-reads local status.
 *
 * Changes in v0.23.10:
 * - Consumes .accent-* / .inset-table catalog (was .evi-*).
 *
 * Changes in v0.23.9:
 * - State memory env key is APP_LIMIT_MEM_STATE.
 *
 * Changes in v1.10.1:
 * - Removed evi- prefix from state container name in error message (evi-state -> state).
 *
 * Changes in v1.10.0:
 * - Disk Status section: loads disk usage via disk-status dispatch command, renders cards
 *   with progress bars and critical/warning banners. Auto-loads on init and on section open.
 *
 * Changes in v1.9.0:
 * - Updates section added to nav. evi-update.js is loaded as a separate script and
 *   handles all update logic autonomously; no changes to admin JS required for navigation
 *   (section switching works for any data-section / #section-* pair automatically).
 *
 * Changes in v1.8.0:
 * - DB Tools section: resolve pgAdmin URL (http://<host>:5445) and set href on #pgadmin-link
 *   on init; no auto window.open — user must click the button.
 *
 * Changes in v1.7.0:
 * - Container Environment: custom TLS certificate upload (manual mode only).
 *   Single multi-file picker; JS auto-detects cert vs key by PEM header.
 *   Files written via cockpit.file().replace() to config/tls/cert.pem and key.pem.
 *   state.configDir populated from DEPLOYMENT_DIR in get-defaults output.
 *
 * Changes in v1.6.2:
 * - Removed CORS origins display (EVI_CORS_ORIGINS): state field, updateCorsDisplay function, form element ref, and all call sites.
 *
 * Changes in v1.6.1:
 * - Removed EVI_HTTP_PORT and EVI_HTTPS_PORT from form (applyEnvObjectToForm, collectEnvFromForm, envDiff, patchLines).
 * - btn-env-regen-cert DOM ref now resolved from new inline location next to TLS mode select.
 *
 * Changes in v1.6.0:
 * - EVI_ADMIN_TOOLS_VERSION constant: single source of truth for panel version, rendered into header on init.
 *
 * Changes in v1.5.0:
 * - Container Environment: env-load, diff modal, env-apply via EVI_COCKPIT_ENV_PATCH_B64, regen TLS, limit selects
 *
 * Changes in v1.4.0:
 * - Password Management: validate new/confirm, spawn admin-set-password with EVI_ADMIN_NEW_PASSWORD, status + output stream
 *
 * Changes in v1.3.4:
 * - Default backup path changed from ~/evi/config/backup to ~/evi/config/backup (deploy kit / runtime config split).
 *
 * Changes in v1.3.3:
 * - Progress bar: smooth tracking during image export via "Writing manifest" sub-steps (50% weight),
 *   remaining steps mapped to 50-100%; total steps detected dynamically from output
 *
 * Changes in v1.3.2:
 * - get-defaults and mkdir: run as current user so DEFAULT_BACKUP_DIR is e.g. /home/user/evi/config/backup not /root/evi/config/backup
 *
 * Changes in v1.3.1:
 * - Backup spawn: run as current user (no superuser) so rootless podman containers are visible
 *
 * Changes in v1.3.0:
 * - Estimate: strip ANSI codes and extract JSON from mixed stderr+stdout so formatted table always shows
 * - Backup location: keep ~/evi/config/backup in UI; resolve to absolute path only when calling scripts
 * - Password visibility toggle (eye icon) for encryption password field
 * - Progress bar during backup with step count from [✓] lines in script output
 *
 * Changes in v1.2.0:
 * - Estimate Size renders human-readable formatted summary instead of raw JSON output
 * - Pre-filled backup location ~/evi/config/backup; loadDefaults only overwrites when field is empty
 * - Backup directory auto-created if it does not exist (mkdir -p before backup-create)
 *
 * Changes in v1.1.0:
 * - Sync Cockpit theme (dark/light) via parent computed background-color + MutationObserver
 */

(function () {
  'use strict';

  /* =====================================================================
   * Theme sync — inherit Cockpit shell dark/light theme
   * ===================================================================== */

  /* Determine if an rgb/rgba color string is "dark" (luminance < 0.4) */
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

  /* Deferred sync: wait for browser to recalculate styles after class mutation */
  function syncTheme() {
    requestAnimationFrame(function() {
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

  var DISPATCH_PATH = '/usr/local/share/cockpit/app-admin/admin-dispatch.sh';

  /* =====================================================================
   * Panel version — single source of truth; rendered into the header on init
   * ===================================================================== */

  var ADMIN_TOOLS_VERSION = 'v0.28.9';

  /* =====================================================================
   * DOM references (populated in init)
   * ===================================================================== */

  var els = {};

  /* =====================================================================
   * State
   * ===================================================================== */

  var state = {
    backupRunning: false,
    passwordRunning: false,
    envApplyRunning: false,
    currentProcess: null,
    defaultBackupDir: '',
    backupOutputBuffer: '',
    envSnapshot: null,
    configDir: '',
    certPemContent: null,
    keyPemContent: null,
    diskOpRunning: false,
    diskStatusInfo: null,
    pendingStorageDiff: null
  };

  var MEM_LIMIT_VALUES = ['10%', '20%', '30%', '40%', '50%', '60%', '70%', '80%'];

  var LIMIT_ROWS = [
    { idSuf: 'proxy', keyMem: 'APP_LIMIT_MEM_PROXY' },
    { idSuf: 'fe', keyMem: 'APP_LIMIT_MEM_FE' },
    { idSuf: 'be', keyMem: 'APP_LIMIT_MEM_BE' },
    { idSuf: 'db', keyMem: 'APP_LIMIT_MEM_DB' },
    { idSuf: 'state', keyMem: 'APP_LIMIT_MEM_STATE' },
    { idSuf: 'worker', keyMem: 'APP_LIMIT_MEM_WORKER' },
    { idSuf: 'fs', keyMem: 'APP_LIMIT_MEM_FS' }
  ];

  /* =====================================================================
   * Navigation — switch between sections
   * ===================================================================== */

  function initNavigation() {
    var navItems = document.querySelectorAll('.admin-nav-item');
    for (var i = 0; i < navItems.length; i++) {
      navItems[i].addEventListener('click', onNavClick);
    }
  }

  function onNavClick(e) {
    var item = e.currentTarget;
    if (item.classList.contains('disabled')) return;

    var sectionId = item.getAttribute('data-section');
    if (!sectionId) return;

    // Update nav active state
    var navItems = document.querySelectorAll('.admin-nav-item');
    for (var i = 0; i < navItems.length; i++) {
      navItems[i].classList.remove('active');
    }
    item.classList.add('active');

    // Show corresponding section, hide others
    var sections = document.querySelectorAll('.admin-section');
    for (var j = 0; j < sections.length; j++) {
      sections[j].classList.add('hidden');
    }
    var target = document.getElementById('section-' + sectionId);
    if (target) {
      target.classList.remove('hidden');
    }

    if (sectionId === 'container-env') {
      loadContainerEnv();
    }
    if (sectionId === 'disk-status') {
      loadDiskStatus();
    }
    if (sectionId === 'updates') {
      document.dispatchEvent(new CustomEvent('updates-panel-show'));
    }
  }

  /* =====================================================================
   * Backup form — show/hide password, validate, collect values
   * ===================================================================== */

  function initBackupForm() {
    // Toggle password field visibility
    els.encryptCheckbox.addEventListener('change', function () {
      if (els.encryptCheckbox.checked) {
        els.passwordGroup.classList.remove('hidden');
      } else {
        els.passwordGroup.classList.add('hidden');
        els.passwordInput.value = '';
      }
    });

    // Start Backup button
    els.btnStart.addEventListener('click', startBackup);

    // Estimate button
    els.btnEstimate.addEventListener('click', estimateBackup);

    // Clear output button
    els.btnClear.addEventListener('click', clearOutput);

    // Password visibility toggle (eye icon)
    if (els.btnTogglePassword) {
      els.btnTogglePassword.addEventListener('click', function () {
        var isPassword = els.passwordInput.type === 'password';
        els.passwordInput.type = isPassword ? 'text' : 'password';
        if (els.iconEye) els.iconEye.classList.toggle('hidden', isPassword);
        if (els.iconEyeOff) els.iconEyeOff.classList.toggle('hidden', !isPassword);
        els.btnTogglePassword.setAttribute('title', isPassword ? 'Hide password' : 'Show password');
        els.btnTogglePassword.setAttribute('aria-label', isPassword ? 'Hide password' : 'Show password');
      });
    }
  }

  /* Resolved backup directory for scripts: show ~/app/config/backup in UI, pass absolute path to scripts */
  function getResolvedBackupDir() {
    var raw = els.dirInput.value.trim();
    if (!raw || raw === '~/app/config/backup') {
      return state.defaultBackupDir || raw || '~/app/config/backup';
    }
    return raw;
  }

  /* Collect form values into an environment variable array for cockpit.spawn */
  function collectBackupEnv() {
    var env = [
      'BACKUP_DIR=' + getResolvedBackupDir(),
      'BACKUP_COMPRESSION=' + els.compressionSelect.value,
      'BACKUP_NONINTERACTIVE=true'
    ];

    if (els.encryptCheckbox.checked) {
      env.push('BACKUP_ENCRYPT=true');
      env.push('BACKUP_PASSWORD=' + els.passwordInput.value);
    } else {
      env.push('BACKUP_ENCRYPT=false');
    }

    return env;
  }

  /* Validate form before starting backup */
  function validateBackupForm() {
    var dir = els.dirInput.value.trim();
    if (!dir) {
      showStatus('error', 'Please specify a backup location.');
      return false;
    }
    if (els.encryptCheckbox.checked && !els.passwordInput.value) {
      showStatus('error', 'Please enter an encryption password or uncheck the encryption option.');
      return false;
    }
    return true;
  }

  /* =====================================================================
   * Backup execution — cockpit.spawn() with streaming output
   * ===================================================================== */

  function startBackup() {
    if (state.backupRunning) return;
    if (!validateBackupForm()) return;

    state.backupRunning = true;
    setFormEnabled(false);
    clearOutput();
    showOutput();
    showStatus('running', 'Preparing backup directory...');

    var backupDir = getResolvedBackupDir();

    // Ensure backup directory exists (mkdir -p); run as current user so path matches backup-create
    var mkdirProc = cockpit.spawn(['mkdir', '-p', backupDir], {
      err: 'out'
    });

    mkdirProc.catch(function (ex) {
      state.backupRunning = false;
      setFormEnabled(true);
      showStatus('error', 'Failed to create backup directory: ' + (ex.message || backupDir));
      return;
    });

    mkdirProc.then(function () {
      runBackup();
    });
  }

  /* Execute the actual backup after directory is ready */
  function runBackup() {
    showStatus('running', 'Backup in progress...');
    state.backupOutputBuffer = '';
    showProgressIndeterminate();

    var envVars = collectBackupEnv();

    var proc = cockpit.spawn([DISPATCH_PATH, 'backup-create'], {
      environ: envVars,
      err: 'out'
    });

    state.currentProcess = proc;

    proc.stream(function (data) {
      appendOutput(data);
      state.backupOutputBuffer += data;
      updateProgressFromBackupOutput();
    });

    proc.then(function () {
      state.backupRunning = false;
      state.currentProcess = null;
      setFormEnabled(true);
      hideProgress();
      showStatus('success', 'Backup completed successfully.');
    });

    proc.catch(function (ex) {
      state.backupRunning = false;
      state.currentProcess = null;
      setFormEnabled(true);
      hideProgress();
      var msg = 'Backup failed.';
      if (ex.exit_status) {
        msg += ' Exit code: ' + ex.exit_status + '.';
      }
      if (ex.message) {
        msg += ' ' + ex.message;
      }
      showStatus('error', msg);
    });
  }

  /* Progress bar: show initial state */
  function showProgressIndeterminate() {
    if (!els.progressWrapper) return;
    els.progressWrapper.classList.remove('hidden');
    if (els.progressFill) {
      els.progressFill.classList.remove('admin-progress-indeterminate');
      els.progressFill.style.width = '0%';
    }
    if (els.progressText) els.progressText.textContent = 'Starting backup...';
  }

  /*
   * Progress bar: update from backup output.
   *
   * The backup script outputs [✓] for each completed step and "Writing manifest
   * to image destination" for each container image saved.  The first phase
   * (image export) is by far the longest, so we give it proportional weight
   * based on "Writing manifest" sub-steps (one per image: fe, be, db, caddy,
   * state, worker, fs, and optionally pgadmin = 7 core images plus optional pgadmin).
   * After image export finishes ([✓]),
   * the remaining steps proceed quickly and each gets equal weight.
   */
  function updateProgressFromBackupOutput() {
    if (!els.progressFill || !els.progressText) return;
    var cleaned = stripAnsi(state.backupOutputBuffer);

    // Count completed steps ([✓] markers)
    var lines = cleaned.split('\n');
    var completedSteps = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('[✓]') !== -1) completedSteps++;
    }

    // Determine total steps from output: base 13 + pgadmin + encryption if present
    var totalSteps = 13;
    if (cleaned.indexOf('copying pgadmin') !== -1) totalSteps++;
    if (cleaned.indexOf('encrypting archive') !== -1) totalSteps++;
    // Before any step finishes, assume 13 (minimum)
    if (totalSteps < 13) totalSteps = 13;

    // During image export (step 0 completed, longest phase): show sub-progress
    // by counting "Writing manifest to image destination" lines (one per image)
    if (completedSteps === 0) {
      var manifestCount = 0;
      for (var j = 0; j < lines.length; j++) {
        if (lines[j].indexOf('Writing manifest to image destination') !== -1) manifestCount++;
      }
      if (manifestCount > 0) {
        // Image export is ~50% of total time; 7 core images + optional pgadmin
        var expectedImages = 7;
        var imageProgress = Math.min(manifestCount / expectedImages, 1.0);
        var pct = Math.round(imageProgress * 50);
        els.progressFill.classList.remove('admin-progress-indeterminate');
        els.progressFill.style.width = pct + '%';
        els.progressText.textContent = 'Exporting images... (' + manifestCount + ' of ~' + expectedImages + ')';
      } else if (cleaned.indexOf('exporting container images') !== -1) {
        // Export started but no image finished yet — show indeterminate
        els.progressFill.classList.add('admin-progress-indeterminate');
        els.progressText.textContent = 'Exporting container images...';
      }
      return;
    }

    // After at least one [✓]: map completed steps to 50-100% range
    // (image export = 50%, remaining steps share the other 50%)
    els.progressFill.classList.remove('admin-progress-indeterminate');
    var remainingSteps = totalSteps - 1; // steps after image export
    var stepsAfterImages = completedSteps - 1; // how many of those are done
    var pctAfter = remainingSteps > 0 ? Math.round(50 + (stepsAfterImages / remainingSteps) * 50) : 100;
    pctAfter = Math.min(pctAfter, 100);
    els.progressFill.style.width = pctAfter + '%';
    els.progressText.textContent = 'Step ' + completedSteps + ' of ' + totalSteps + ' completed';
  }

  /* Progress bar: hide */
  function hideProgress() {
    if (els.progressWrapper) els.progressWrapper.classList.add('hidden');
  }

  function estimateBackup() {
    if (state.backupRunning) return;

    clearOutput();
    showOutput();
    showStatus('running', 'Estimating backup size...');
    setFormEnabled(false);

    var backupDir = getResolvedBackupDir() || '~/app/config/backup';
    var collected = '';

    var proc = cockpit.spawn([DISPATCH_PATH, 'backup-estimate', backupDir], {
      err: 'out'
    });

    proc.stream(function (data) {
      collected += data;
    });

    proc.then(function () {
      setFormEnabled(true);
      var formatted = formatEstimate(collected);
      els.output.textContent = formatted;
      showStatus('success', 'Estimation complete.');
    });

    proc.catch(function (ex) {
      setFormEnabled(true);
      // If JSON parsing fails, show raw output as fallback
      if (collected) {
        els.output.textContent = collected;
      }
      var msg = 'Estimation failed.';
      if (ex.message) msg += ' ' + ex.message;
      showStatus('error', msg);
    });
  }

  /* =====================================================================
   * Format estimate JSON into human-readable summary
   * ===================================================================== */

  /* Convert bytes to human-readable string (KB, MB, GB) */
  function formatBytes(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + ' MB';
    if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return bytes + ' B';
  }

  /* Convert seconds to readable duration */
  function formatDuration(seconds) {
    if (seconds >= 3600) {
      var h = Math.floor(seconds / 3600);
      var m = Math.floor((seconds % 3600) / 60);
      return h + ' h ' + m + ' min';
    }
    if (seconds >= 60) {
      var min = Math.floor(seconds / 60);
      var sec = seconds % 60;
      return min + ' min ' + sec + ' sec';
    }
    return seconds + ' sec';
  }

  /* Pad string to fixed width (right-aligned for numbers) */
  function padLeft(str, len) {
    while (str.length < len) str = ' ' + str;
    return str;
  }

  function padRight(str, len) {
    while (str.length < len) str = str + ' ';
    return str;
  }

  /* Strip ANSI escape sequences from script output */
  function stripAnsi(str) {
    return str.replace(/\x1b\[[0-9;]*m/g, '');
  }

  /* Extract JSON object from mixed output (stderr + stdout); returns { json: string, prefix: string } */
  function extractJsonFromOutput(raw) {
    var cleaned = stripAnsi(raw);
    var first = cleaned.indexOf('{');
    var last = cleaned.lastIndexOf('}');
    if (first === -1 || last === -1 || last < first) {
      return { json: null, prefix: cleaned.trim() };
    }
    return {
      json: cleaned.slice(first, last + 1),
      prefix: cleaned.slice(0, first).trim()
    };
  }

  /* Parse backup-estimate.sh JSON and render formatted text */
  function formatEstimate(rawOutput) {
    var extracted = extractJsonFromOutput(rawOutput);
    var data;
    try {
      if (!extracted.json) {
        throw new Error('No JSON found');
      }
      data = JSON.parse(extracted.json);
    } catch (e) {
      return 'Could not parse estimate data.\n\n' + stripAnsi(rawOutput);
    }

    var lines = [];
    if (extracted.prefix) {
      lines.push(extracted.prefix);
      lines.push('');
    }
    var sep = '─'.repeat(52);

    lines.push('  BACKUP SIZE ESTIMATE');
    lines.push(sep);
    lines.push('');
    lines.push('  Backup Components:');
    lines.push('');
    lines.push('    ' + padRight('Container images', 28) + padLeft(formatBytes(data.images_bytes || 0), 12));
    lines.push('    ' + padRight('Database', 28) + padLeft(formatBytes(data.database_bytes || 0), 12));
    lines.push('    ' + padRight('Environment files', 28) + padLeft(formatBytes(data.env_bytes || 0), 12));
    lines.push('    ' + padRight('TLS certificates', 28) + padLeft(formatBytes(data.tls_bytes || 0), 12));
    lines.push('    ' + padRight('JWT secrets', 28) + padLeft(formatBytes(data.jwt_bytes || 0), 12));
    lines.push('    ' + padRight('File storage (fs_data)', 28) + padLeft(formatBytes(data.fs_volume_bytes || 0), 12));
    lines.push('    ' + padRight('State store (state_data)', 28) + padLeft(formatBytes(data.state_volume_bytes || 0), 12));

    if (data.pgadmin_bytes > 0) {
      lines.push('    ' + padRight('pgAdmin data', 28) + padLeft(formatBytes(data.pgadmin_bytes), 12));
    }

    lines.push('    ' + padRight('Installation scripts', 28) + padLeft(formatBytes(data.install_repo_bytes || 0), 12));
    lines.push('    ' + '─'.repeat(40));
    lines.push('    ' + padRight('Total (raw)', 28) + padLeft(formatBytes(data.total_raw_bytes || data.total_uncompressed_bytes || 0), 12));
    lines.push('');

    // Compression options
    var ce = data.compression_estimates || {};
    lines.push(sep);
    lines.push('');
    lines.push('  Compression Options:');
    lines.push('');
    lines.push('    ' + padRight('Method', 22) + padLeft('Result size', 14) + padLeft('Est. time', 14));
    lines.push('    ' + '─'.repeat(50));

    if (ce['gzip-standard']) {
      lines.push('    ' + padRight('gzip (standard)', 22) +
        padLeft(formatBytes(ce['gzip-standard'].size_bytes || 0), 14) +
        padLeft(formatDuration(ce['gzip-standard'].time_seconds || 0), 14));
    }
    if (ce['zstd-fast']) {
      lines.push('    ' + padRight('zstd (fast)', 22) +
        padLeft(formatBytes(ce['zstd-fast'].size_bytes || 0), 14) +
        padLeft(formatDuration(ce['zstd-fast'].time_seconds || 0), 14));
    }
    if (ce['zstd-max']) {
      lines.push('    ' + padRight('zstd (max)', 22) +
        padLeft(formatBytes(ce['zstd-max'].size_bytes || 0), 14) +
        padLeft(formatDuration(ce['zstd-max'].time_seconds || 0), 14));
    }

    lines.push('');

    // Disk space
    lines.push(sep);
    lines.push('');
    lines.push('  Disk Space:');
    lines.push('');
    lines.push('    ' + padRight('Backup location', 28) + (data.target_directory || '?'));
    lines.push('    ' + padRight('Available space', 28) + formatBytes(data.available_bytes || 0));

    if (data.same_disk_as_app) {
      lines.push('');
      lines.push('    Note: backup location is on the same disk as application data.');
      lines.push('    Consider using an external or mounted drive for safety.');
    }

    // Enough space check
    var estCompressed = data.estimated_compressed_bytes || 0;
    var available = data.available_bytes || 0;
    lines.push('');
    if (available > 0 && estCompressed > 0) {
      if (available > estCompressed * 1.5) {
        lines.push('    Sufficient space available for backup.');
      } else if (available > estCompressed) {
        lines.push('    Space is tight. Consider freeing up disk before backup.');
      } else {
        lines.push('    WARNING: Not enough disk space for estimated backup size!');
      }
    }

    lines.push('');

    return lines.join('\n');
  }

  /* =====================================================================
   * UI helpers — status, output, form toggle
   * ===================================================================== */

  function showStatus(type, message) {
    els.backupStatus.textContent = message;
    els.backupStatus.className = 'admin-status status-' + type;
    els.backupStatus.classList.remove('hidden');
  }

  function hideStatus() {
    els.backupStatus.classList.add('hidden');
    els.backupStatus.className = 'admin-status hidden';
  }

  function showPasswordStatus(type, message) {
    els.passwordStatus.textContent = message;
    els.passwordStatus.className = 'admin-status status-' + type;
    els.passwordStatus.classList.remove('hidden');
  }

  function hidePasswordStatus() {
    els.passwordStatus.classList.add('hidden');
    els.passwordStatus.className = 'admin-status hidden';
  }

  function showOutput() {
    els.outputWrapper.classList.remove('hidden');
  }

  function appendOutput(text) {
    els.output.textContent += text;
    // Auto-scroll to bottom
    els.output.scrollTop = els.output.scrollHeight;
  }

  function clearOutput() {
    els.output.textContent = '';
    els.outputWrapper.classList.add('hidden');
    hideStatus();
    hideProgress();
  }

  function showPasswordOutput() {
    els.passwordOutputWrapper.classList.remove('hidden');
  }

  function appendPasswordOutput(text) {
    els.passwordOutput.textContent += text;
    els.passwordOutput.scrollTop = els.passwordOutput.scrollHeight;
  }

  function clearPasswordOutput() {
    els.passwordOutput.textContent = '';
    els.passwordOutputWrapper.classList.add('hidden');
    hidePasswordStatus();
  }

  function setFormEnabled(enabled) {
    els.btnStart.disabled = !enabled;
    els.btnEstimate.disabled = !enabled;
    els.dirInput.disabled = !enabled;
    els.compressionSelect.disabled = !enabled;
    els.encryptCheckbox.disabled = !enabled;
    els.passwordInput.disabled = !enabled;
  }

  function setPasswordFormEnabled(enabled) {
    els.btnPasswordSet.disabled = !enabled;
    els.adminPasswordNew.disabled = !enabled;
    els.adminPasswordConfirm.disabled = !enabled;
  }

  function validatePasswordForm() {
    var a = els.adminPasswordNew.value;
    var b = els.adminPasswordConfirm.value;
    if (!a || !b) {
      showPasswordStatus('error', 'Please enter and confirm the new password.');
      return false;
    }
    if (a !== b) {
      showPasswordStatus('error', 'The two password fields do not match.');
      return false;
    }
    return true;
  }

  function startSetAdminPassword() {
    if (state.passwordRunning) return;
    if (!validatePasswordForm()) return;

    state.passwordRunning = true;
    setPasswordFormEnabled(false);
    clearPasswordOutput();
    showPasswordOutput();
    showPasswordStatus('running', 'Updating password…');

    var pwd = els.adminPasswordNew.value;
    var envVars = ['APP_ADMIN_NEW_PASSWORD=' + pwd];

    var proc = cockpit.spawn([DISPATCH_PATH, 'admin-set-password'], {
      environ: envVars,
      err: 'out'
    });

    state.currentProcess = proc;

    proc.stream(function (data) {
      appendPasswordOutput(data);
    });

    proc.then(function () {
      state.passwordRunning = false;
      state.currentProcess = null;
      setPasswordFormEnabled(true);
      els.adminPasswordNew.value = '';
      els.adminPasswordConfirm.value = '';
      showPasswordStatus('success', 'Password updated successfully. Sign in again with the new password.');
    });

    proc.catch(function (ex) {
      state.passwordRunning = false;
      state.currentProcess = null;
      setPasswordFormEnabled(true);
      var msg = 'Password change failed.';
      if (ex.exit_status === 5) {
        msg = 'Password was updated in the database, but restarting state failed. Run: systemctl --user restart state';
      } else if (ex.exit_status) {
        msg += ' Exit code: ' + ex.exit_status + '.';
      }
      if (ex.message) {
        msg += ' ' + ex.message;
      }
      showPasswordStatus('error', msg);
    });
  }

  function initPasswordForm() {
    els.btnPasswordSet.addEventListener('click', startSetAdminPassword);
    if (els.btnPasswordOutputClear) {
      els.btnPasswordOutputClear.addEventListener('click', clearPasswordOutput);
    }
  }

  /* =====================================================================
   * Container Environment
   * ===================================================================== */

  function utf8ToBase64(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  function parseEnvLines(text) {
    var out = {};
    var lines = text.replace(/\r\n/g, '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line || line.indexOf('ERROR:') === 0) continue;
      var eq = line.indexOf('=');
      if (eq === -1) continue;
      var k = line.slice(0, eq);
      out[k] = line.slice(eq + 1);
    }
    return out;
  }

  function buildLimitSelectOptions(selectEl, values) {
    selectEl.innerHTML = '';
    var o0 = document.createElement('option');
    o0.value = '';
    o0.textContent = 'No limit';
    selectEl.appendChild(o0);
    for (var i = 0; i < values.length; i++) {
      var o = document.createElement('option');
      o.value = values[i];
      o.textContent = values[i];
      selectEl.appendChild(o);
    }
  }

  function setLimitSelectValue(selectEl, value) {
    var v = value == null ? '' : String(value).trim();
    var found = false;
    for (var i = 0; i < selectEl.options.length; i++) {
      if (selectEl.options[i].value === v) {
        found = true;
        break;
      }
    }
    if (!found && v !== '') {
      var o = document.createElement('option');
      o.value = v;
      o.textContent = v + ' (custom)';
      selectEl.appendChild(o);
    }
    selectEl.value = v;
  }

  function updateTlsDependentUi() {
    var manual = els.envTlsMode && els.envTlsMode.value === 'manual';
    if (els.envAcmeGroup) {
      els.envAcmeGroup.classList.toggle('hidden', manual);
    }
    if (els.btnEnvRegenCert) {
      els.btnEnvRegenCert.classList.toggle('hidden', !manual);
    }
    if (els.envCertUploadGroup) {
      var wasVisible = !els.envCertUploadGroup.classList.contains('hidden');
      els.envCertUploadGroup.classList.toggle('hidden', !manual);
      if (!manual && wasVisible) {
        state.certPemContent = null;
        state.keyPemContent = null;
        if (els.inputCertFiles) els.inputCertFiles.value = '';
        if (els.envCertSelectedNames) els.envCertSelectedNames.textContent = '';
        if (els.btnCertDoUpload) els.btnCertDoUpload.disabled = true;
      }
    }
  }

  function updateFirewallAllowedVisibility() {
    var v = els.envFirewallAccess ? els.envFirewallAccess.value : '';
    var show = v === 'allowed_ips' || v === 'allowed_cidr';
    if (els.envFirewallAllowedGroup) {
      els.envFirewallAllowedGroup.classList.toggle('hidden', !show);
    }
  }

  function updateDomainWarning() {
    if (!els.envDomainWarning || !els.envDomain || !state.envSnapshot) return;
    var cur = els.envDomain.value.trim();
    var orig = (state.envSnapshot.APP_DOMAIN || '').trim();
    els.envDomainWarning.classList.toggle('hidden', cur === orig);
  }

  function applyEnvObjectToForm(env) {
    if (!env) return;
    if (els.envDomain) els.envDomain.value = env.APP_DOMAIN || '';
    if (els.envTlsMode) els.envTlsMode.value = env.APP_TLS_MODE === 'manual' ? 'manual' : 'letsencrypt';
    if (els.envAcmeEmail) els.envAcmeEmail.value = env.APP_ACME_EMAIL || '';
    if (els.envFirewallAccess) {
      var fa = env.APP_FIREWALL_ADMIN_ACCESS || 'localhost';
      if (['localhost', 'allowed_ips', 'allowed_cidr', 'any', 'skip'].indexOf(fa) === -1) fa = 'localhost';
      els.envFirewallAccess.value = fa;
    }
    if (els.envFirewallAllowed) els.envFirewallAllowed.value = env.APP_FIREWALL_ADMIN_ALLOWED || '';

    for (var r = 0; r < LIMIT_ROWS.length; r++) {
      var row = LIMIT_ROWS[r];
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      var memVal = env[row.keyMem] == null ? '' : String(env[row.keyMem]).trim();
      if (row.keyMem === 'APP_LIMIT_MEM_STATE' &&
          (memVal === '' || memVal === '256m' || memVal === '512m' ||
           memVal === '1g' || memVal === '2g' || memVal === '4g' || memVal === '8g')) {
        memVal = '10%';
        env[row.keyMem] = '10%';
      }
      if (sm) setLimitSelectValue(sm, memVal);
    }

    updateTlsDependentUi();
    updateFirewallAllowedVisibility();
    updateDomainWarning();
  }

  function collectEnvFromForm() {
    var o = {};
    o.APP_DOMAIN = els.envDomain ? els.envDomain.value.trim() : '';
    o.APP_TLS_MODE = els.envTlsMode ? els.envTlsMode.value : 'letsencrypt';
    if (o.APP_TLS_MODE === 'manual') {
      o.APP_ACME_EMAIL = '';
    } else {
      o.APP_ACME_EMAIL = els.envAcmeEmail ? els.envAcmeEmail.value.trim() : '';
    }
    o.APP_FIREWALL_ADMIN_ACCESS = els.envFirewallAccess ? els.envFirewallAccess.value : 'localhost';
    o.APP_FIREWALL_ADMIN_ALLOWED = els.envFirewallAllowed ? els.envFirewallAllowed.value.trim() : '';

    for (var r = 0; r < LIMIT_ROWS.length; r++) {
      var row = LIMIT_ROWS[r];
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      o[row.keyMem] = sm ? sm.value.trim() : '';
    }
    return o;
  }

  function envDiff(snapshot, current) {
    var keys = [
      'APP_DOMAIN', 'APP_TLS_MODE', 'APP_ACME_EMAIL',
      'APP_FIREWALL_ADMIN_ACCESS', 'APP_FIREWALL_ADMIN_ALLOWED'
    ];
    for (var i = 0; i < LIMIT_ROWS.length; i++) {
      keys.push(LIMIT_ROWS[i].keyMem);
    }
    var lines = [];
    for (var j = 0; j < keys.length; j++) {
      var k = keys[j];
      var a = snapshot[k] == null ? '' : String(snapshot[k]);
      var b = current[k] == null ? '' : String(current[k]);
      if (a !== b) {
        lines.push(k + '\n  was: ' + (a === '' ? '(empty)' : a) + '\n  now: ' + (b === '' ? '(empty)' : b) + '\n');
      }
    }
    return lines;
  }

  function showEnvStatus(type, message) {
    if (!els.envContainerStatus) return;
    els.envContainerStatus.textContent = message;
    els.envContainerStatus.className = 'admin-status status-' + type;
    els.envContainerStatus.classList.remove('hidden');
  }

  function hideEnvStatus() {
    if (!els.envContainerStatus) return;
    els.envContainerStatus.classList.add('hidden');
  }

  function showEnvOutput() {
    if (els.envContainerOutputWrapper) els.envContainerOutputWrapper.classList.remove('hidden');
  }

  function appendEnvOutput(text) {
    if (!els.envContainerOutput) return;
    els.envContainerOutput.textContent += text;
    els.envContainerOutput.scrollTop = els.envContainerOutput.scrollHeight;
  }

  function clearEnvOutput() {
    if (els.envContainerOutput) els.envContainerOutput.textContent = '';
    if (els.envContainerOutputWrapper) els.envContainerOutputWrapper.classList.add('hidden');
    hideEnvStatus();
    if (els.envContainerProgress) els.envContainerProgress.classList.add('hidden');
  }

  function setEnvFormEnabled(enabled) {
    if (els.btnEnvApply) els.btnEnvApply.disabled = !enabled;
    if (els.btnEnvRegenCert) els.btnEnvRegenCert.disabled = !enabled;
    if (els.btnCertSelect) els.btnCertSelect.disabled = !enabled;
    if (els.inputCertFiles) els.inputCertFiles.disabled = !enabled;
    if (els.btnCertDoUpload) els.btnCertDoUpload.disabled = !enabled || (!state.certPemContent && !state.keyPemContent);
    if (els.formContainerEnv) {
      var inputs = els.formContainerEnv.querySelectorAll('input, select, button');
      for (var i = 0; i < inputs.length; i++) {
        if (inputs[i].id === 'btn-env-apply' || inputs[i].id === 'btn-env-regen-cert') continue;
        if (inputs[i].id === 'btn-cert-select' || inputs[i].id === 'input-cert-files' || inputs[i].id === 'btn-cert-do-upload') continue;
        inputs[i].disabled = !enabled;
      }
    }
  }

  function loadContainerEnv() {
    if (!els.envDomain) return;
    showEnvStatus('running', 'Loading configuration…');
    var proc = cockpit.spawn([DISPATCH_PATH, 'env-load'], { err: 'out' });
    proc.then(function (data) {
      var env = parseEnvLines(data);
      state.envSnapshot = env;
      applyEnvObjectToForm(env);
      hideEnvStatus();
    });
    proc.catch(function (ex) {
      showEnvStatus('error', 'Could not load app.env: ' + (ex.message || 'unknown error'));
    });
  }

  function openEnvDiffModal(text) {
    if (els.envDiffBody) els.envDiffBody.textContent = text;
    if (els.envDiffModal) {
      els.envDiffModal.classList.remove('hidden');
      els.envDiffModal.setAttribute('aria-hidden', 'false');
    }
  }

  function closeEnvDiffModal() {
    if (els.envDiffModal) {
      els.envDiffModal.classList.add('hidden');
      els.envDiffModal.setAttribute('aria-hidden', 'true');
    }
  }

  function onApplyContainerEnvClick() {
    if (state.envApplyRunning || !state.envSnapshot) return;
    var current = collectEnvFromForm();
    var diffLines = envDiff(state.envSnapshot, current);
    if (diffLines.length === 0) {
      showEnvStatus('error', 'No changes to apply.');
      return;
    }
    openEnvDiffModal(diffLines.join('\n'));
  }

  function runEnvApplyConfirmed() {
    closeEnvDiffModal();
    if (state.envApplyRunning) return;
    var current = collectEnvFromForm();
    var diffLines = envDiff(state.envSnapshot, current);
    if (diffLines.length === 0) return;

    state.envApplyRunning = true;
    setEnvFormEnabled(false);
    clearEnvOutput();
    showEnvOutput();
    showEnvStatus('running', 'Applying configuration and restarting containers…');
    if (els.envContainerProgress) {
      els.envContainerProgress.classList.remove('hidden');
      if (els.envContainerProgressFill) {
        els.envContainerProgressFill.classList.add('admin-progress-indeterminate');
      }
    }

    var patchLines = [];
    var keys = [
      'APP_DOMAIN', 'APP_TLS_MODE', 'APP_ACME_EMAIL',
      'APP_FIREWALL_ADMIN_ACCESS', 'APP_FIREWALL_ADMIN_ALLOWED'
    ];
    for (var i = 0; i < LIMIT_ROWS.length; i++) {
      keys.push(LIMIT_ROWS[i].keyMem);
    }
    for (var j = 0; j < keys.length; j++) {
      var k = keys[j];
      var a = state.envSnapshot[k] == null ? '' : String(state.envSnapshot[k]);
      var b = current[k] == null ? '' : String(current[k]);
      if (a !== b) {
        patchLines.push(k + '=' + b);
      }
    }

    var b64 = utf8ToBase64(patchLines.join('\n') + '\n');
    var proc = cockpit.spawn([DISPATCH_PATH, 'env-apply'], {
      environ: ['APP_COCKPIT_ENV_PATCH_B64=' + b64],
      err: 'out'
    });
    state.currentProcess = proc;

    proc.stream(function (data) {
      appendEnvOutput(data);
    });

    proc.then(function () {
      state.envApplyRunning = false;
      state.currentProcess = null;
      setEnvFormEnabled(true);
      if (els.envContainerProgress) els.envContainerProgress.classList.add('hidden');
      showEnvStatus('success', 'Configuration applied and containers restarted.');
      loadContainerEnv();
    });

    proc.catch(function (ex) {
      state.envApplyRunning = false;
      state.currentProcess = null;
      setEnvFormEnabled(true);
      if (els.envContainerProgress) els.envContainerProgress.classList.add('hidden');
      var msg = 'Apply failed.';
      if (ex.exit_status) msg += ' Exit code: ' + ex.exit_status + '.';
      if (ex.message) msg += ' ' + ex.message;
      showEnvStatus('error', msg);
    });
  }

  function onRegenCertClick() {
    if (state.envApplyRunning) return;
    state.envApplyRunning = true;
    setEnvFormEnabled(false);
    clearEnvOutput();
    showEnvOutput();
    showEnvStatus('running', 'Regenerating TLS certificate…');
    if (els.envContainerProgress) {
      els.envContainerProgress.classList.remove('hidden');
      if (els.envContainerProgressFill) {
        els.envContainerProgressFill.classList.add('admin-progress-indeterminate');
      }
    }

    var proc = cockpit.spawn([DISPATCH_PATH, 'env-regen-cert'], { err: 'out' });
    state.currentProcess = proc;
    proc.stream(function (data) {
      appendEnvOutput(data);
    });
    proc.then(function () {
      state.envApplyRunning = false;
      state.currentProcess = null;
      setEnvFormEnabled(true);
      if (els.envContainerProgress) els.envContainerProgress.classList.add('hidden');
      showEnvStatus('success', 'TLS certificate regenerated. Install app-tls.crt on clients to trust HTTPS (manual mode).');
    });
    proc.catch(function (ex) {
      state.envApplyRunning = false;
      state.currentProcess = null;
      setEnvFormEnabled(true);
      if (els.envContainerProgress) els.envContainerProgress.classList.add('hidden');
      var msg = 'Certificate generation failed.';
      if (ex.exit_status) msg += ' Exit code: ' + ex.exit_status + '.';
      if (ex.message) msg += ' ' + ex.message;
      showEnvStatus('error', msg);
    });
  }

  /* =====================================================================
   * Custom TLS certificate upload
   * ===================================================================== */

  function onCertFilesSelected() {
    var files = els.inputCertFiles ? els.inputCertFiles.files : null;
    state.certPemContent = null;
    state.keyPemContent = null;
    if (!files || !files.length) return;

    var names = [];
    var pending = files.length;

    for (var i = 0; i < files.length; i++) {
      (function (file) {
        var reader = new FileReader();
        reader.onload = function (e) {
          var text = e.target.result;
          if (text.indexOf('-----BEGIN CERTIFICATE-----') !== -1) {
            state.certPemContent = text;
            names.push('cert: ' + file.name);
          } else if (text.indexOf('BEGIN') !== -1 && text.indexOf('KEY') !== -1) {
            state.keyPemContent = text;
            names.push('key: ' + file.name);
          } else {
            names.push(file.name + ' (unrecognized)');
          }
          pending--;
          if (pending === 0) {
            if (els.envCertSelectedNames) els.envCertSelectedNames.textContent = names.join('  |  ');
            if (els.btnCertDoUpload) els.btnCertDoUpload.disabled = (!state.certPemContent && !state.keyPemContent);
          }
        };
        reader.readAsText(file);
      })(files[i]);
    }
  }

  function uploadCertFiles() {
    if (!state.certPemContent && !state.keyPemContent) return;
    if (!state.configDir) {
      showEnvStatus('error', 'Deployment directory not resolved. Please reload the page.');
      return;
    }
    var tlsDir = state.configDir + '/tls';
    setEnvFormEnabled(false);
    showEnvStatus('running', 'Uploading certificate files\u2026');
    var promises = [];
    if (state.certPemContent) {
      promises.push(cockpit.file(tlsDir + '/cert.pem', { superuser: 'try' }).replace(state.certPemContent));
    }
    if (state.keyPemContent) {
      promises.push(cockpit.file(tlsDir + '/key.pem', { superuser: 'try' }).replace(state.keyPemContent));
    }
    Promise.all(promises).then(function () {
      setEnvFormEnabled(true);
      showEnvStatus('success', 'Certificate files saved to config/tls/. Restart containers to apply.');
    }).catch(function (err) {
      setEnvFormEnabled(true);
      showEnvStatus('error', 'Upload failed: ' + (err.message || String(err)));
    });
  }

  function initContainerEnvSection() {
    if (!els.formContainerEnv) return;

    for (var r = 0; r < LIMIT_ROWS.length; r++) {
      var row = LIMIT_ROWS[r];
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      if (sm) buildLimitSelectOptions(sm, MEM_LIMIT_VALUES);
    }

    if (els.envTlsMode) {
      els.envTlsMode.addEventListener('change', updateTlsDependentUi);
    }
    if (els.envFirewallAccess) {
      els.envFirewallAccess.addEventListener('change', updateFirewallAllowedVisibility);
    }
    if (els.envDomain) {
      els.envDomain.addEventListener('input', function () {
        updateDomainWarning();
      });
    }

    if (els.btnEnvApply) {
      els.btnEnvApply.addEventListener('click', onApplyContainerEnvClick);
    }
    if (els.btnEnvRegenCert) {
      els.btnEnvRegenCert.addEventListener('click', onRegenCertClick);
    }
    if (els.btnEnvOutputClear) {
      els.btnEnvOutputClear.addEventListener('click', clearEnvOutput);
    }
    if (els.btnEnvDiffCancel) {
      els.btnEnvDiffCancel.addEventListener('click', closeEnvDiffModal);
    }
    if (els.btnEnvDiffConfirm) {
      els.btnEnvDiffConfirm.addEventListener('click', runEnvApplyConfirmed);
    }
    if (els.envDiffModal) {
      els.envDiffModal.querySelector('.admin-modal-backdrop').addEventListener('click', closeEnvDiffModal);
    }

    if (els.btnCertSelect) {
      els.btnCertSelect.addEventListener('click', function () {
        if (els.inputCertFiles) els.inputCertFiles.click();
      });
    }
    if (els.inputCertFiles) {
      els.inputCertFiles.addEventListener('change', onCertFilesSelected);
    }
    if (els.btnCertDoUpload) {
      els.btnCertDoUpload.addEventListener('click', uploadCertFiles);
    }

    updateTlsDependentUi();
    updateFirewallAllowedVisibility();
  }

  /* =====================================================================
   * Disk Status section
   * ===================================================================== */

  var DONUT_CIRCUMFERENCE = 2 * Math.PI * 52;
  var DISK_ROLE_ORDER = ['system', 'db', 'fs', 'state', 'backups'];
  var DISK_ROLE_LABELS = {
    system: 'System',
    db: 'Database',
    fs: 'File storage',
    state: 'State',
    backups: 'Backups'
  };
  var DISK_SEG_CLASSES = {
    'disk-seg-db': true,
    'disk-seg-fs': true,
    'disk-seg-state': true,
    'disk-seg-images': true,
    'disk-seg-backups': true,
    'disk-seg-updates': true,
    'disk-seg-other': true,
    'disk-seg-free': true
  };

  function diskHelpersReady() {
    return typeof normalizeDiskList === 'function' &&
      typeof buildDonutSegments === 'function' &&
      typeof deriveDiskAlerts === 'function' &&
      typeof computeStorageDiff === 'function';
  }

  function setDiskStatus(type, message) {
    var statusMsg = document.getElementById('disk-status-msg');
    if (!statusMsg) return;
    statusMsg.textContent = message;
    statusMsg.className = 'admin-status status-' + type;
  }

  function loadDiskStatus(options) {
    var keepStatus = !!(options && options.keepStatus);
    var cardsEl = document.getElementById('disk-cards');
    if (!cardsEl) return;
    if (state.diskOpRunning && !keepStatus) return;
    if (!diskHelpersReady()) {
      setDiskStatus('error', 'Disk status helpers did not load.');
      return;
    }
    if (!keepStatus) {
      setDiskStatus('running', 'Loading disk status…');
    }

    var proc = cockpit.spawn([DISPATCH_PATH, 'disk-status'], { err: 'out' });
    proc.then(function (data) {
      var info;
      try {
        info = JSON.parse(data);
      } catch (e) {
        setDiskStatus('error', 'Could not parse disk status.');
        return;
      }
      state.diskStatusInfo = info;
      renderDiskBanners(info);
      renderDiskCards(cardsEl, info);
      populateDiskStorageForm(info);
      renderDiskCleanupPanel(info);
      if (!keepStatus) {
        var statusMsg = document.getElementById('disk-status-msg');
        if (statusMsg && statusMsg.className.indexOf('status-running') !== -1) {
          statusMsg.classList.add('hidden');
        }
      }
    });
    proc.catch(function (ex) {
      setDiskStatus('error', 'Failed to load disk status: ' + ((ex && ex.message) || 'unknown error'));
    });
    return proc;
  }

  function setBanner(el, show, label, message) {
    var strong;
    if (!el) return;
    if (!show) {
      el.classList.add('hidden');
      return;
    }
    el.classList.remove('hidden');
    el.textContent = '';
    strong = document.createElement('strong');
    strong.textContent = label;
    el.appendChild(strong);
    el.appendChild(document.createTextNode(' ' + message));
  }

  function joinMounts(mounts) {
    var parts = [];
    var i;
    for (i = 0; i < mounts.length; i++) {
      if (mounts[i]) parts.push(mounts[i]);
    }
    if (parts.length === 0) return '';
    if (parts.length === 1) return parts[0];
    if (parts.length === 2) return parts[0] + ' and ' + parts[1];
    return parts.slice(0, -1).join(', ') + ', and ' + parts[parts.length - 1];
  }

  function renderDiskBanners(info) {
    var alerts = deriveDiskAlerts(info);
    var disks = normalizeDiskList(info);
    var multi = disks.length > 1;
    var critMsg = 'Disk space is critically low. Free up space immediately to prevent service interruption.';
    var warnMsg = 'Disk space is running low. Consider freeing up space or expanding the disk.';
    if (multi && alerts.criticalDisks.length > 0) {
      critMsg = 'Disk space is critically low on ' + joinMounts(alerts.criticalDisks) + '. Free up space immediately to prevent service interruption.';
    }
    if (multi && alerts.warningDisks.length > 0) {
      warnMsg = 'Disk space is running low on ' + joinMounts(alerts.warningDisks) + '. Consider freeing up space or expanding the disk.';
    }
    setBanner(
      document.getElementById('disk-critical-banner'),
      alerts.critical,
      'Critical:',
      critMsg
    );
    setBanner(
      document.getElementById('disk-warning-banner'),
      alerts.warning,
      'Warning:',
      warnMsg
    );
    setBanner(
      document.getElementById('disk-ceiling-banner'),
      alerts.fsCeilingWarning,
      'Warning:',
      alerts.fsCeilingMessage || 'The file storage capacity ceiling exceeds the disk that hosts file storage.'
    );
  }

  function renderDiskCards(container, info) {
    var disks = normalizeDiskList(info);
    var i;
    var empty;
    container.textContent = '';
    if (!disks.length) {
      empty = document.createElement('p');
      empty.className = 'admin-hint';
      empty.textContent = 'No mounted disks reported.';
      container.appendChild(empty);
      return;
    }
    for (i = 0; i < disks.length; i++) {
      container.appendChild(buildDiskCard(disks[i]));
    }
  }

  function roleListHas(roles, key) {
    var i;
    if (!roles) return false;
    for (i = 0; i < roles.length; i++) {
      if (roles[i] === key) return true;
    }
    return false;
  }

  function diskRoleBadges(roles) {
    var html = '';
    var i;
    var key;
    var any = false;
    for (i = 0; i < DISK_ROLE_ORDER.length; i++) {
      key = DISK_ROLE_ORDER[i];
      if (!roleListHas(roles, key)) continue;
      any = true;
      html += '<span class="admin-disk-role-badge">' + escapeHtml(DISK_ROLE_LABELS[key]) + '</span>';
    }
    if (!any) {
      html = '<span class="admin-disk-role-badge admin-disk-role-badge-available">Available mount</span>';
    }
    return html;
  }

  function diskSubtitle(disk) {
    var mount = disk.mount_point || '/';
    var device = disk.device || '';
    var fstype = disk.fstype || '';
    var detail = '';
    if (device && fstype && fstype !== 'unknown') detail = device + ' (' + fstype + ')';
    else if (device) detail = device;
    else if (fstype && fstype !== 'unknown') detail = fstype;
    if (!detail) return mount;
    return mount + ' \u2014 ' + detail;
  }

  function formatUsePercent(pct) {
    var n = Number(pct);
    var rounded;
    if (typeof n !== 'number' || !isFinite(n)) n = 0;
    rounded = Math.round(n * 10) / 10;
    if (Math.abs(rounded - Math.round(rounded)) < 1e-9) return String(Math.round(rounded));
    return rounded.toFixed(1);
  }

  function formatShare(item) {
    var bytes = Number(item && item.bytes) || 0;
    var pct = Number(item && item.pct);
    if (!isFinite(pct)) pct = 0;
    if (bytes > 0 && pct < 0.1) return '<0.1%';
    if (pct === 0) return '0%';
    return pct.toFixed(1) + '%';
  }

  function safeSegClass(colorClass) {
    if (DISK_SEG_CLASSES[colorClass]) return colorClass;
    return '';
  }

  function isSafeDash(value) {
    return typeof value === 'string' && /^[\d.\- ]+$/.test(value);
  }

  function donutArcsHtml(arcs) {
    var html = '';
    var i;
    var arc;
    if (!arcs) return html;
    for (i = 0; i < arcs.length; i++) {
      arc = arcs[i];
      if (!arc || arc.key === 'free') continue;
      if (!isSafeDash(arc.dashArray) || !isSafeDash(arc.dashOffset)) continue;
      html += '<circle class="admin-donut-seg ' + safeSegClass(arc.colorClass) + '" cx="70" cy="70" r="52"' +
        ' stroke-dasharray="' + arc.dashArray + '" stroke-dashoffset="' + arc.dashOffset + '"></circle>';
    }
    return html;
  }

  function donutLegendHtml(legend) {
    var html = '';
    var i;
    var item;
    if (!legend) return html;
    for (i = 0; i < legend.length; i++) {
      item = legend[i];
      html += '<div class="admin-disk-legend-row">' +
        '<span class="admin-disk-swatch ' + safeSegClass(item.colorClass) + '"></span>' +
        '<span class="admin-disk-legend-label">' + escapeHtml(item.label || '') + '</span>' +
        '<span class="admin-disk-legend-bytes">' + escapeHtml(formatBytes(item.bytes || 0)) + '</span>' +
        '<span class="admin-disk-legend-pct">' + escapeHtml(formatShare(item)) + '</span>' +
        '</div>';
    }
    return html;
  }

  function buildDiskCard(disk) {
    var card = document.createElement('div');
    var donut = buildDonutSegments(disk, DONUT_CIRCUMFERENCE);
    var title = disk.is_system ? 'System disk' : ('Mounted disk: ' + (disk.mount_point || ''));
    var levelClass = '';
    var usedStr = formatBytes(disk.used_bytes || 0);
    var availStr = formatBytes(disk.avail_bytes || 0);
    var totalStr = formatBytes(disk.total_bytes || 0);
    if (donut.level === 'critical') levelClass = ' admin-disk-card-critical';
    else if (donut.level === 'warning') levelClass = ' admin-disk-card-warning';
    card.className = 'admin-disk-card' + levelClass;
    card.innerHTML =
      '<div class="admin-disk-card-head">' +
        '<h4 class="admin-disk-card-title">' + escapeHtml(title) + '</h4>' +
        '<p class="admin-disk-card-path">' + escapeHtml(diskSubtitle(disk)) + '</p>' +
      '</div>' +
      '<div class="admin-disk-roles">' + diskRoleBadges(disk.roles) + '</div>' +
      '<div class="admin-disk-card-body">' +
        '<div class="admin-disk-donut-col">' +
          '<div class="admin-donut-wrap">' +
            '<svg class="admin-donut" width="140" height="140" viewBox="0 0 140 140" aria-hidden="true">' +
              '<circle class="admin-donut-track" cx="70" cy="70" r="52"></circle>' +
              '<g transform="rotate(-90 70 70)">' + donutArcsHtml(donut.arcs) + '</g>' +
            '</svg>' +
            '<div class="admin-donut-center">' +
              '<span class="admin-donut-pct status-level-' + escapeHtml(donut.level || 'ok') + '">' +
                escapeHtml(formatUsePercent(donut.usePercent)) + '%</span>' +
              '<span class="admin-donut-sub">used</span>' +
            '</div>' +
          '</div>' +
          '<div class="admin-disk-totals">' + escapeHtml(usedStr) + ' used &middot; ' +
            escapeHtml(availStr) + ' free &middot; ' + escapeHtml(totalStr) + ' total</div>' +
        '</div>' +
        '<div class="admin-disk-legend-col">' +
          '<div class="admin-disk-legend">' + donutLegendHtml(donut.legend) + '</div>' +
        '</div>' +
      '</div>';
    return card;
  }

  function uniquePush(list, value) {
    var i;
    if (value == null || value === '') return;
    for (i = 0; i < list.length; i++) {
      if (list[i] === value) return;
    }
    list.push(value);
  }

  function stripSlash(value) {
    var s = String(value == null ? '' : value).trim();
    while (s.length > 1 && s.charAt(s.length - 1) === '/') s = s.slice(0, -1);
    return s;
  }

  function mountFromStoredPath(path) {
    var p = stripSlash(path);
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

  function fsChoiceFromStoredPath(path) {
    var raw = stripSlash(path);
    if (raw === '' || raw === 'same') return 'same';
    if (raw === 'system' || raw === '/') return '/';
    return mountFromStoredPath(raw);
  }

  function placementMatches(cfg, dataMount, fsMount, gb) {
    var diff = computeStorageDiff(cfg, {
      dataTargetMount: dataMount,
      fsTargetMount: fsMount,
      fsVolumeMaxGb: gb
    });
    return !diff.relocatesDbState && !diff.relocatesFs && !diff.changesFsLimit;
  }

  function storageCeilingGb(cfg) {
    var n = Number(cfg && cfg.fs_volume_max_gb);
    if (typeof n !== 'number' || !isFinite(n)) return '';
    return String(Math.round(n));
  }

  function writableExtraMounts(disks) {
    var out = [];
    var i;
    var mount;
    for (i = 0; i < disks.length; i++) {
      if (!disks[i] || !disks[i].writable || disks[i].is_system) continue;
      mount = disks[i].mount_point || '';
      if (!mount || mount === '/') continue;
      uniquePush(out, mount);
    }
    out.sort(function (a, b) {
      if (a < b) return -1;
      if (a > b) return 1;
      return 0;
    });
    return out;
  }

  function choosePlacement(cfg, extraMounts) {
    var gbText = storageCeilingGb(cfg);
    var gb = gbText === '' ? '' : Number(gbText);
    var dbCandidates = [];
    var fsCandidates = [];
    var i;
    var j;
    var dbMount;
    var fsMount;
    uniquePush(dbCandidates, mountFromStoredPath(cfg.app_data_path));
    if (cfg.effective_db_mount != null && String(cfg.effective_db_mount).trim() !== '') {
      uniquePush(dbCandidates, mountFromStoredPath(cfg.effective_db_mount));
    }
    uniquePush(dbCandidates, '/');
    for (i = 0; i < extraMounts.length; i++) uniquePush(dbCandidates, extraMounts[i]);

    uniquePush(fsCandidates, fsChoiceFromStoredPath(cfg.app_fs_data_path));
    uniquePush(fsCandidates, 'same');
    uniquePush(fsCandidates, '/');
    for (i = 0; i < extraMounts.length; i++) uniquePush(fsCandidates, extraMounts[i]);

    if (gb !== '') {
      for (i = 0; i < dbCandidates.length; i++) {
        for (j = 0; j < fsCandidates.length; j++) {
          if (placementMatches(cfg, dbCandidates[i], fsCandidates[j], gb)) {
            return { db: dbCandidates[i], fs: fsCandidates[j] };
          }
        }
      }
    }

    dbMount = mountFromStoredPath(cfg.app_data_path);
    if (cfg.effective_db_mount != null && String(cfg.effective_db_mount).trim() !== '') {
      dbMount = mountFromStoredPath(cfg.effective_db_mount);
    }
    fsMount = fsChoiceFromStoredPath(cfg.app_fs_data_path);
    return { db: dbMount, fs: fsMount };
  }

  function fillSelect(select, options, selected) {
    var i;
    var opt;
    var found = false;
    select.textContent = '';
    for (i = 0; i < options.length; i++) {
      opt = document.createElement('option');
      opt.value = options[i].value;
      opt.textContent = options[i].label;
      if (options[i].value === selected) found = true;
      select.appendChild(opt);
    }
    if (!found && selected) {
      opt = document.createElement('option');
      opt.value = selected;
      opt.textContent = selected;
      select.appendChild(opt);
    }
    select.value = selected;
  }

  function selectedFsMountPoint() {
    var fs = document.getElementById('disk-select-fs-mount');
    var db = document.getElementById('disk-select-db-mount');
    var fsVal = fs ? fs.value : 'same';
    var dbVal = db && db.value ? db.value : '/';
    if (fsVal === 'same' || fsVal === '') return dbVal || '/';
    return fsVal;
  }

  function updateFsCapacityHint() {
    var hint = document.getElementById('disk-fs-max-hint');
    var mount;
    var disks;
    var i;
    var found = null;
    if (!hint) return;
    mount = selectedFsMountPoint();
    disks = normalizeDiskList(state.diskStatusInfo || {});
    for (i = 0; i < disks.length; i++) {
      if (disks[i].mount_point === mount) {
        found = disks[i];
        break;
      }
    }
    if (!found) {
      hint.textContent = 'No size data for ' + mount + '.';
      return;
    }
    hint.textContent = formatBytes(found.avail_bytes || 0) + ' free of ' +
      formatBytes(found.total_bytes || 0) + ' on ' + mount + '.';
  }

  function populateDiskStorageForm(info) {
    var cfg = (info && info.storage_config) || {};
    var disks = normalizeDiskList(info);
    var extra = writableExtraMounts(disks);
    var chosen = choosePlacement(cfg, extra);
    var dbSelect = document.getElementById('disk-select-db-mount');
    var fsSelect = document.getElementById('disk-select-fs-mount');
    var gbInput = document.getElementById('disk-input-fs-max-gb');
    var dbOptions = [{ value: '/', label: 'System disk (/) \u2014 default' }];
    var fsOptions = [
      { value: 'same', label: 'Same disk as database (follow APP_DATA_PATH)' },
      { value: '/', label: 'System disk (/)' }
    ];
    var i;
    for (i = 0; i < extra.length; i++) {
      dbOptions.push({ value: extra[i], label: extra[i] });
      fsOptions.push({ value: extra[i], label: extra[i] });
    }
    if (dbSelect) fillSelect(dbSelect, dbOptions, chosen.db);
    if (fsSelect) fillSelect(fsSelect, fsOptions, chosen.fs);
    if (gbInput) gbInput.value = storageCeilingGb(cfg);
    updateFsCapacityHint();
  }

  function formatStagedLabel(version) {
    var v = String(version);
    if (v.charAt(0) === 'v' || v.charAt(0) === 'V') return v;
    return 'v' + v;
  }

  function formatBackupWhen(mtime) {
    var d;
    var iso;
    if (mtime == null || mtime === '') return '';
    d = new Date(mtime);
    if (isNaN(d.getTime())) return String(mtime);
    iso = d.toISOString();
    return iso.substring(0, 16).replace('T', ' ') + ' UTC';
  }

  function renderBackupList(backups) {
    var list = document.getElementById('disk-cleanup-backups-list');
    var i;
    var item;
    var row;
    var nameEl;
    var sizeEl;
    var dateEl;
    var btn;
    if (!list) return;
    list.textContent = '';
    if (!backups || !backups.length) return;
    for (i = 0; i < backups.length; i++) {
      item = backups[i] || {};
      row = document.createElement('div');
      row.className = 'admin-disk-backup-row';
      nameEl = document.createElement('span');
      nameEl.className = 'admin-disk-backup-name';
      nameEl.textContent = item.name || '';
      sizeEl = document.createElement('span');
      sizeEl.className = 'admin-disk-backup-size';
      sizeEl.textContent = formatBytes(item.size_bytes || 0);
      dateEl = document.createElement('span');
      dateEl.className = 'admin-disk-backup-date';
      dateEl.textContent = formatBackupWhen(item.mtime);
      btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'admin-btn admin-btn-small';
      btn.textContent = 'Delete';
      btn.setAttribute('data-backup-name', item.name || '');
      btn.disabled = !!state.diskOpRunning || !item.name;
      row.appendChild(nameEl);
      row.appendChild(sizeEl);
      row.appendChild(dateEl);
      row.appendChild(btn);
      list.appendChild(row);
    }
  }

  function renderDiskCleanupPanel(info) {
    var cleanup = (info && info.cleanup) || {};
    var count = Number(cleanup.unused_images_count) || 0;
    var imageBytes = Number(cleanup.unused_images_bytes) || 0;
    var stagedBytes = Number(cleanup.staged_updates_bytes) || 0;
    var stagedVersion = cleanup.staged_version;
    var backupBytes = Number(cleanup.backups_bytes) || 0;
    var backups = Array.isArray(cleanup.backups) ? cleanup.backups : [];
    var imagesEl = document.getElementById('disk-cleanup-images-info');
    var updatesEl = document.getElementById('disk-cleanup-updates-info');
    var summaryEl = document.getElementById('disk-cleanup-backups-summary');
    if (imagesEl) {
      if (count === 0) imagesEl.textContent = 'No unused images';
      else imagesEl.textContent = count + ' unused image' + (count === 1 ? '' : 's') + ' (' + formatBytes(imageBytes) + ')';
    }
    if (updatesEl) {
      if (stagedBytes === 0 && !stagedVersion) updatesEl.textContent = 'No staged update files';
      else if (stagedVersion) updatesEl.textContent = formatStagedLabel(stagedVersion) + ' (' + formatBytes(stagedBytes) + ')';
      else updatesEl.textContent = formatBytes(stagedBytes);
    }
    if (summaryEl) {
      if (backupBytes === 0 && backups.length === 0) summaryEl.textContent = 'No backup archives';
      else summaryEl.textContent = formatBytes(backupBytes) + ' total';
    }
    renderBackupList(backups);
    syncDiskActionButtons();
  }

  function syncDiskActionButtons() {
    var info = state.diskStatusInfo || {};
    var cleanup = info.cleanup || {};
    var busy = !!state.diskOpRunning;
    var count = Number(cleanup.unused_images_count) || 0;
    var stagedBytes = Number(cleanup.staged_updates_bytes) || 0;
    var stagedVersion = cleanup.staged_version;
    var prune = document.getElementById('btn-disk-prune-images');
    var clearUp = document.getElementById('btn-disk-clear-updates');
    var apply = document.getElementById('btn-disk-storage-apply');
    var refresh = document.getElementById('btn-disk-refresh');
    var deletes;
    var i;
    if (prune) prune.disabled = busy || count === 0;
    if (clearUp) clearUp.disabled = busy || (stagedBytes === 0 && !stagedVersion);
    if (apply) apply.disabled = busy;
    if (refresh) refresh.disabled = busy;
    deletes = document.querySelectorAll('#disk-cleanup-backups-list button');
    for (i = 0; i < deletes.length; i++) deletes[i].disabled = busy || !deletes[i].getAttribute('data-backup-name');
  }

  function appendDiskOpOutput(text) {
    var out = document.getElementById('disk-op-output');
    if (!out || text == null) return;
    out.textContent += text;
    out.scrollTop = out.scrollHeight;
  }

  function beginDiskOp(message) {
    var progress = document.getElementById('disk-op-progress');
    var fill = document.getElementById('disk-op-progress-fill');
    var text = document.getElementById('disk-op-progress-text');
    var wrap = document.getElementById('disk-op-output-wrapper');
    var out = document.getElementById('disk-op-output');
    state.diskOpRunning = true;
    if (progress) progress.classList.remove('hidden');
    if (fill) fill.classList.add('admin-progress-indeterminate');
    if (text) text.textContent = message;
    if (wrap) wrap.classList.remove('hidden');
    if (out) out.textContent = '';
    setDiskStatus('running', message);
    syncDiskActionButtons();
  }

  function finishDiskOp(ok, message) {
    var progress = document.getElementById('disk-op-progress');
    state.diskOpRunning = false;
    state.pendingStorageDiff = null;
    if (progress) progress.classList.add('hidden');
    setDiskStatus(ok ? 'success' : 'error', message);
    syncDiskActionButtons();
    loadDiskStatus({ keepStatus: true });
  }

  function watchDiskOp(proc, successMessage, failureLead) {
    if (proc.stream) {
      proc.stream(function (data) {
        appendDiskOpOutput(data);
      });
    }
    proc.then(function () {
      finishDiskOp(true, successMessage);
    });
    proc.catch(function (ex) {
      var msg = failureLead;
      if (ex && ex.exit_status) msg += ' Exit code: ' + ex.exit_status + '.';
      if (ex && ex.message) msg += ' ' + ex.message;
      finishDiskOp(false, msg);
    });
  }

  function cleanupSuccessMessage(action) {
    if (action === 'prune-images') return 'Unused images pruned.';
    if (action === 'clear-updates') return 'Staged update files cleared.';
    return 'Backup archive deleted.';
  }

  function cleanupFailureLead(action) {
    if (action === 'prune-images') return 'Prune unused images failed.';
    if (action === 'clear-updates') return 'Clear staged updates failed.';
    return 'Delete backup failed.';
  }

  function cleanupRunningMessage(action) {
    if (action === 'prune-images') return 'Pruning unused images…';
    if (action === 'clear-updates') return 'Clearing staged updates…';
    return 'Deleting backup archive…';
  }

  function runDiskCleanup(action, arg) {
    var args;
    var proc;
    if (state.diskOpRunning) return;
    if (action === 'delete-backup' && !arg) return;
    args = [DISPATCH_PATH, 'disk-cleanup', action];
    if (action === 'delete-backup') args.push(arg);
    beginDiskOp(cleanupRunningMessage(action));
    proc = cockpit.spawn(args, { err: 'out' });
    watchDiskOp(proc, cleanupSuccessMessage(action), cleanupFailureLead(action));
  }

  function readStorageForm() {
    var db = document.getElementById('disk-select-db-mount');
    var fs = document.getElementById('disk-select-fs-mount');
    var gb = document.getElementById('disk-input-fs-max-gb');
    return {
      dataTargetMount: db ? db.value : '/',
      fsTargetMount: fs ? fs.value : 'same',
      fsVolumeMaxGb: gb ? String(gb.value).trim() : ''
    };
  }

  function openDiskStorageModal() {
    var modal = document.getElementById('disk-storage-modal');
    if (!modal) return;
    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
  }

  function closeDiskStorageModal() {
    var modal = document.getElementById('disk-storage-modal');
    if (!modal) return;
    modal.classList.add('hidden');
    modal.setAttribute('aria-hidden', 'true');
  }

  function onApplyDiskStorageClick() {
    var form;
    var gb;
    var diff;
    var body;
    if (state.diskOpRunning) return;
    if (!state.diskStatusInfo) {
      setDiskStatus('error', 'Disk status is not loaded yet.');
      return;
    }
    if (!diskHelpersReady()) {
      setDiskStatus('error', 'Disk status helpers did not load.');
      return;
    }
    form = readStorageForm();
    gb = Number(form.fsVolumeMaxGb);
    if (!/^[0-9]+$/.test(form.fsVolumeMaxGb) || !isFinite(gb) || gb < 1) {
      setDiskStatus('error', 'File storage capacity ceiling must be a whole number of gigabytes, at least 1.');
      return;
    }
    form.fsVolumeMaxGb = gb;
    diff = computeStorageDiff(state.diskStatusInfo.storage_config || {}, form);
    if (!diff.hasChanges) {
      setDiskStatus('error', 'No storage changes to apply.');
      return;
    }
    state.pendingStorageDiff = diff;
    body = document.getElementById('disk-storage-diff-body');
    if (body) body.textContent = (diff.summaryLines || []).join('\n');
    openDiskStorageModal();
  }

  function runDiskStorageApplyConfirmed() {
    var diff = state.pendingStorageDiff;
    closeDiskStorageModal();
    if (!diff || state.diskOpRunning) return;
    beginDiskOp('Applying storage changes…');
    var proc = cockpit.spawn([DISPATCH_PATH, 'disk-storage-apply'], {
      environ: [
        'APP_NEW_DATA_PATH=' + diff.newAppDataPath,
        'APP_NEW_FS_DATA_PATH=' + diff.newAppFsDataPath,
        'APP_NEW_FS_VOLUME_MAX_GB=' + String(diff.newFsVolumeMaxGb)
      ],
      err: 'out'
    });
    watchDiskOp(proc, 'Storage changes applied.', 'Storage changes failed.');
  }

  function clearDiskOpOutput() {
    var out = document.getElementById('disk-op-output');
    if (out) out.textContent = '';
  }

  function onDeleteBackupClick(e) {
    var node = e.target;
    var name;
    while (node && node.id !== 'disk-cleanup-backups-list') {
      if (node.getAttribute && node.tagName === 'BUTTON' && node.getAttribute('data-backup-name') != null) {
        if (node.disabled || state.diskOpRunning) return;
        name = node.getAttribute('data-backup-name');
        if (name) runDiskCleanup('delete-backup', name);
        return;
      }
      node = node.parentNode;
    }
  }

  function initDiskStatus() {
    var refresh = document.getElementById('btn-disk-refresh');
    var db = document.getElementById('disk-select-db-mount');
    var fs = document.getElementById('disk-select-fs-mount');
    var apply = document.getElementById('btn-disk-storage-apply');
    var prune = document.getElementById('btn-disk-prune-images');
    var clearUp = document.getElementById('btn-disk-clear-updates');
    var list = document.getElementById('disk-cleanup-backups-list');
    var clearOut = document.getElementById('btn-disk-output-clear');
    var cancel = document.getElementById('btn-disk-storage-cancel');
    var confirmBtn = document.getElementById('btn-disk-storage-confirm');
    var modal = document.getElementById('disk-storage-modal');
    var backdrop;
    if (refresh) refresh.addEventListener('click', function () { loadDiskStatus(); });
    if (db) db.addEventListener('change', updateFsCapacityHint);
    if (fs) fs.addEventListener('change', updateFsCapacityHint);
    if (apply) apply.addEventListener('click', onApplyDiskStorageClick);
    if (prune) prune.addEventListener('click', function () { runDiskCleanup('prune-images'); });
    if (clearUp) clearUp.addEventListener('click', function () { runDiskCleanup('clear-updates'); });
    if (list) list.addEventListener('click', onDeleteBackupClick);
    if (clearOut) clearOut.addEventListener('click', clearDiskOpOutput);
    if (cancel) cancel.addEventListener('click', closeDiskStorageModal);
    if (confirmBtn) confirmBtn.addEventListener('click', runDiskStorageApplyConfirmed);
    if (modal) {
      backdrop = modal.querySelector('.admin-modal-backdrop');
      if (backdrop) backdrop.addEventListener('click', closeDiskStorageModal);
    }
  }

  function escapeHtml(str) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  /* =====================================================================
   * Load defaults — get deployment directory from dispatcher
   * ===================================================================== */

  function loadDefaults() {
    // The backup location is pre-filled to ~/app/config/backup in the HTML value attribute.
    // The dispatcher get-defaults provides the resolved home directory path (must run as current user, not root).
    var proc = cockpit.spawn([DISPATCH_PATH, 'get-defaults'], {
      err: 'out'
    });

    proc.then(function (data) {
      var lines = data.split('\n');
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split('=');
        if (parts.length >= 2) {
          var key = parts[0];
          var val = parts.slice(1).join('=');
          if (key === 'DEFAULT_BACKUP_DIR' && val) {
            state.defaultBackupDir = val;
            // Keep ~/app/config/backup in the UI; resolved path is used only when calling scripts
          }
          if (key === 'DEPLOYMENT_DIR' && val) {
            state.configDir = val + '/config';
          }
        }
      }
    });

    proc.catch(function () {
      // Dispatcher not installed — keep the pre-filled ~/app/config/backup value
    });
  }

  /* =====================================================================
   * Initialization
   * ===================================================================== */

  function init() {
    // Cache DOM references
    els.dirInput = document.getElementById('backup-dir');
    els.compressionSelect = document.getElementById('backup-compression');
    els.encryptCheckbox = document.getElementById('backup-encrypt');
    els.passwordGroup = document.getElementById('password-group');
    els.passwordInput = document.getElementById('backup-password');
    els.btnTogglePassword = document.getElementById('btn-toggle-password');
    els.iconEye = els.btnTogglePassword ? els.btnTogglePassword.querySelector('.admin-icon-eye') : null;
    els.iconEyeOff = els.btnTogglePassword ? els.btnTogglePassword.querySelector('.admin-icon-eye-off') : null;
    els.btnStart = document.getElementById('btn-backup-start');
    els.btnEstimate = document.getElementById('btn-backup-estimate');
    els.btnClear = document.getElementById('btn-backup-clear');
    els.backupStatus = document.getElementById('backup-status');
    els.progressWrapper = document.getElementById('backup-progress');
    els.progressFill = document.getElementById('backup-progress-fill');
    els.progressText = document.getElementById('backup-progress-text');
    els.outputWrapper = document.getElementById('backup-output-wrapper');
    els.output = document.getElementById('backup-output');

    els.adminPasswordNew = document.getElementById('admin-password-new');
    els.adminPasswordConfirm = document.getElementById('admin-password-confirm');
    els.btnPasswordSet = document.getElementById('btn-admin-password-set');
    els.passwordStatus = document.getElementById('password-status');
    els.passwordOutputWrapper = document.getElementById('password-output-wrapper');
    els.passwordOutput = document.getElementById('password-output');
    els.btnPasswordOutputClear = document.getElementById('btn-password-output-clear');

    els.pgadminLink = document.getElementById('pgadmin-link');
    if (els.pgadminLink) {
      els.pgadminLink.href = 'http://' + window.location.hostname + ':5445';
    }

    els.formContainerEnv = document.getElementById('form-container-env');
    els.envDomain = document.getElementById('env-domain');
    els.envDomainWarning = document.getElementById('env-domain-warning');
    els.envTlsMode = document.getElementById('env-tls-mode');
    els.envAcmeGroup = document.getElementById('env-acme-group');
    els.envAcmeEmail = document.getElementById('env-acme-email');
    els.envFirewallAccess = document.getElementById('env-firewall-access');
    els.envFirewallAllowedGroup = document.getElementById('env-firewall-allowed-group');
    els.envFirewallAllowed = document.getElementById('env-firewall-allowed');
    els.btnEnvApply = document.getElementById('btn-env-apply');
    els.btnEnvRegenCert = document.getElementById('btn-env-regen-cert');
    els.envContainerStatus = document.getElementById('env-container-status');
    els.envContainerProgress = document.getElementById('env-container-progress');
    els.envContainerProgressFill = document.getElementById('env-container-progress-fill');
    els.envContainerOutputWrapper = document.getElementById('env-container-output-wrapper');
    els.envContainerOutput = document.getElementById('env-container-output');
    els.btnEnvOutputClear = document.getElementById('btn-env-output-clear');
    els.envDiffModal = document.getElementById('env-diff-modal');
    els.envDiffBody = document.getElementById('env-diff-body');
    els.btnEnvDiffCancel = document.getElementById('btn-env-diff-cancel');
    els.btnEnvDiffConfirm = document.getElementById('btn-env-diff-confirm');
    els.envCertUploadGroup = document.getElementById('env-cert-upload-group');
    els.btnCertSelect = document.getElementById('btn-cert-select');
    els.inputCertFiles = document.getElementById('input-cert-files');
    els.envCertSelectedNames = document.getElementById('env-cert-selected-names');
    els.btnCertDoUpload = document.getElementById('btn-cert-do-upload');

    initNavigation();
    initBackupForm();
    if (els.btnPasswordSet && els.adminPasswordNew && els.adminPasswordConfirm && els.passwordStatus) {
      initPasswordForm();
    }
    initContainerEnvSection();
    loadDefaults();

    initDiskStatus();
    loadDiskStatus();

    var versionEl = document.getElementById('admin-version');
    if (versionEl) { versionEl.textContent = ADMIN_TOOLS_VERSION; }
  }

  // Boot
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
