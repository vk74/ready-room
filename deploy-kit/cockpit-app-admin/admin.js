/* Version: 0.26.3
 * Purpose: Main logic for application admin tools Cockpit package.
 * Handles navigation between sections, backup form interactions, and command execution
 * via Cockpit API (cockpit.spawn). Each admin function calls scripts through the
 * admin-dispatch.sh dispatcher that resolves paths to deployment scripts.
 * Cockpit package; filename: admin.js
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

  var ADMIN_TOOLS_VERSION = 'v0.26.3';

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
    keyPemContent: null
  };

  var CPU_LIMIT_VALUES = ['0.25', '0.5', '1', '2', '4'];
  var MEM_LIMIT_VALUES = ['256m', '512m', '1g', '2g', '4g', '8g'];

  var LIMIT_ROWS = [
    { idSuf: 'proxy', keyCpu: 'APP_LIMIT_CPU_PROXY', keyMem: 'APP_LIMIT_MEM_PROXY' },
    { idSuf: 'fe', keyCpu: 'APP_LIMIT_CPU_FE', keyMem: 'APP_LIMIT_MEM_FE' },
    { idSuf: 'be', keyCpu: 'APP_LIMIT_CPU_BE', keyMem: 'APP_LIMIT_MEM_BE' },
    { idSuf: 'db', keyCpu: 'APP_LIMIT_CPU_DB', keyMem: 'APP_LIMIT_MEM_DB' },
    { idSuf: 'state', keyCpu: 'APP_LIMIT_CPU_STATE', keyMem: 'APP_LIMIT_MEM_STATE' },
    { idSuf: 'worker', keyCpu: 'APP_LIMIT_CPU_WORKER', keyMem: 'APP_LIMIT_MEM_WORKER' },
    { idSuf: 'fs', keyCpu: 'APP_LIMIT_CPU_FS', keyMem: 'APP_LIMIT_MEM_FS' }
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
      var sc = document.getElementById('env-limit-cpu-' + row.idSuf);
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      if (sc) setLimitSelectValue(sc, env[row.keyCpu] || '');
      if (sm) setLimitSelectValue(sm, env[row.keyMem] || '');
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
      var sc = document.getElementById('env-limit-cpu-' + row.idSuf);
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      o[row.keyCpu] = sc ? sc.value.trim() : '';
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
      keys.push(LIMIT_ROWS[i].keyCpu, LIMIT_ROWS[i].keyMem);
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
      keys.push(LIMIT_ROWS[i].keyCpu, LIMIT_ROWS[i].keyMem);
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
      var sc = document.getElementById('env-limit-cpu-' + row.idSuf);
      var sm = document.getElementById('env-limit-mem-' + row.idSuf);
      if (sc) buildLimitSelectOptions(sc, CPU_LIMIT_VALUES);
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

  function loadDiskStatus() {
    var cardsEl = document.getElementById('disk-cards');
    var critBanner = document.getElementById('disk-critical-banner');
    var warnBanner = document.getElementById('disk-warning-banner');
    var statusMsg = document.getElementById('disk-status-msg');
    if (!cardsEl) return;

    if (statusMsg) {
      statusMsg.textContent = 'Loading disk status…';
      statusMsg.className = 'admin-status status-running';
      statusMsg.classList.remove('hidden');
    }

    var proc = cockpit.spawn([DISPATCH_PATH, 'disk-status'], { err: 'out' });
    proc.then(function (data) {
      if (statusMsg) statusMsg.classList.add('hidden');
      var info;
      try {
        info = JSON.parse(data);
      } catch (e) {
        if (statusMsg) {
          statusMsg.textContent = 'Could not parse disk status.';
          statusMsg.className = 'admin-status status-error';
          statusMsg.classList.remove('hidden');
        }
        return;
      }
      renderDiskCards(cardsEl, info);
      if (critBanner) critBanner.classList.toggle('hidden', !info.system_critical && !info.data_critical);
      if (warnBanner) {
        var anyWarn = false;
        if (info.system && info.system.use_percent >= 85 && info.system.use_percent < 95) anyWarn = true;
        if (info.data && info.data.use_percent >= 85 && info.data.use_percent < 95) anyWarn = true;
        warnBanner.classList.toggle('hidden', !anyWarn || info.system_critical || info.data_critical);
      }
    });
    proc.catch(function (ex) {
      if (statusMsg) {
        statusMsg.textContent = 'Failed to load disk status: ' + (ex.message || 'unknown error');
        statusMsg.className = 'admin-status status-error';
        statusMsg.classList.remove('hidden');
      }
    });
  }

  function renderDiskCards(container, info) {
    container.innerHTML = '';
    if (info.system) {
      container.appendChild(buildDiskCard('System disk', '/', info.system));
    }
    if (info.data) {
      container.appendChild(buildDiskCard('Data disk', info.data.path, info.data));
    }
  }

  function buildDiskCard(title, path, disk) {
    var card = document.createElement('div');
    card.className = 'admin-disk-card';

    var pct = disk.use_percent || 0;
    var barClass = 'admin-disk-bar-fill';
    if (pct >= 95) barClass += ' disk-crit';
    else if (pct >= 85) barClass += ' disk-warn';

    var totalStr = formatBytes(disk.total_bytes || 0);
    var usedStr = formatBytes(disk.used_bytes || 0);
    var availStr = formatBytes(disk.avail_bytes || 0);

    card.innerHTML =
      '<h4 class="admin-disk-card-title">' + escapeHtml(title) + '</h4>' +
      '<p class="admin-disk-card-path">' + escapeHtml(path) + '</p>' +
      '<div class="admin-disk-bar-wrapper">' +
        '<div class="admin-disk-bar-track">' +
          '<div class="' + barClass + '" style="width:' + Math.min(pct, 100) + '%"></div>' +
        '</div>' +
        '<span class="admin-disk-bar-pct">' + pct + '%</span>' +
      '</div>' +
      '<div class="admin-disk-details">' +
        totalStr + ' total &middot; ' + usedStr + ' used &middot; ' + availStr + ' free' +
      '</div>';

    return card;
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

    var btnDiskRefresh = document.getElementById('btn-disk-refresh');
    if (btnDiskRefresh) {
      btnDiskRefresh.addEventListener('click', loadDiskStatus);
    }
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
