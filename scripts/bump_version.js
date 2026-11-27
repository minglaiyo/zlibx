#!/usr/bin/env node

/**
 * Olib Version Bumper Script
 *
 * Usage:
 *   node scripts/bump_version.js <new_version>
 *
 * Updates pubspec.yaml and any legacy desktop/publish targets that still
 * exist. Missing legacy files are skipped; an existing target whose
 * version marker cannot be found is an error.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

const FILES = {
  pubspec: path.join(ROOT, 'pubspec.yaml'),
  installer: path.join(ROOT, 'installer.iss'),
  versionJson: path.join(ROOT, 'publish_page', 'version.json'),
  configJs: path.join(ROOT, 'publish_page', 'config.js'),
};

function readFile(filePath) {
  if (!fs.existsSync(filePath)) return null;
  return fs.readFileSync(filePath, 'utf-8');
}

function writeFile(filePath, content) {
  fs.writeFileSync(filePath, content, 'utf-8');
}

function parseSemver(version) {
  const match = version.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) return null;
  return {
    major: parseInt(match[1], 10),
    minor: parseInt(match[2], 10),
    patch: parseInt(match[3], 10),
  };
}

function computeBuildNumber(semver) {
  return semver.major * 10000 + semver.minor * 100 + semver.patch;
}

function getCurrentVersion() {
  const content = readFile(FILES.pubspec);
  if (content === null) throw new Error('missing pubspec.yaml');
  const match = content.match(/^version:\s*(\d+\.\d+\.\d+)\+/m);
  if (!match) throw new Error('pubspec.yaml has no version: x.y.z+build marker');
  return match[1];
}

function requireMatch(content, pattern, label) {
  if (!pattern.test(content)) {
    throw new Error(`${label}: expected version marker was not found`);
  }
}

function finishWrite(filePath, content, original) {
  if (content === original) return 'unchanged';
  writeFile(filePath, content);
  return 'updated';
}

function updatePubspec(version, buildNumber) {
  const original = readFile(FILES.pubspec);
  if (original === null) throw new Error('missing pubspec.yaml');

  const versionPattern = /^(version:\s*)\d+\.\d+\.\d+\+\d+/m;
  requireMatch(original, versionPattern, 'pubspec.yaml');
  let content = original.replace(
    versionPattern,
    `$1${version}+${buildNumber}`,
  );

  const msixPattern = /^(\s*msix_version:\s*)\d+\.\d+\.\d+\.\d+/m;
  if (msixPattern.test(content)) {
    content = content.replace(msixPattern, `$1${version}.0`);
  }

  return finishWrite(FILES.pubspec, content, original);
}

function updateInstaller(version) {
  const original = readFile(FILES.installer);
  if (original === null) return 'missing';

  const pattern = /#define MyAppVersion ".*?"/;
  requireMatch(original, pattern, 'installer.iss');
  const content = original.replace(pattern, `#define MyAppVersion "${version}"`);
  return finishWrite(FILES.installer, content, original);
}

function updateVersionJson(version) {
  const original = readFile(FILES.versionJson);
  if (original === null) return 'missing';

  const json = JSON.parse(original);
  let content = original;
  let changed = false;

  if (json.version !== version) {
    json.version = version;
    changed = true;
  }

  if (json.changelog) {
    for (const locale of ['en', 'zh']) {
      const value = json.changelog[locale];
      if (typeof value !== 'string') continue;
      const updated = value.replace(/v\d+\.\d+\.\d+/, `v${version}`);
      if (updated !== value) {
        json.changelog[locale] = updated;
        changed = true;
      }
    }
  }

  if (!changed) return 'unchanged';
  content = JSON.stringify(json, null, 4) + '\n';
  return finishWrite(FILES.versionJson, content, original);
}

function updateConfigJs(version) {
  const original = readFile(FILES.configJs);
  if (original === null) return 'missing';

  const versionPattern = /(version:\s*')v?\d+\.\d+\.\d+(')/;
  requireMatch(original, versionPattern, 'publish_page/config.js');
  let content = original.replace(versionPattern, `$1v${version}$2`);
  content = content.replace(
    /(o-lib)\d+\.\d+\.\d+(\.apk)/g,
    `$1${version}$2`,
  );
  return finishWrite(FILES.configJs, content, original);
}

function main() {
  const newVersion = process.argv[2];

  if (!newVersion) {
    const current = getCurrentVersion();
    console.log('');
    console.log('Olib Version Bumper');
    console.log('==================');
    console.log(`Current version: ${current}`);
    console.log('');
    console.log('Usage: node scripts/bump_version.js <new_version>');
    console.log('Example: node scripts/bump_version.js 1.0.6');
    console.log('');
    process.exitCode = 1;
    return;
  }

  const semver = parseSemver(newVersion);
  if (!semver) {
    console.error(
      `Invalid version format: "${newVersion}". Expected: x.y.z (e.g. 1.0.6)`,
    );
    process.exitCode = 1;
    return;
  }

  const currentVersion = getCurrentVersion();
  const buildNumber = computeBuildNumber(semver);

  console.log('');
  console.log('Olib Version Bumper');
  console.log('==================');
  console.log(
    `${currentVersion} -> ${newVersion} (build ${buildNumber})`,
  );
  console.log('');

  const updates = [
    { name: 'pubspec.yaml', fn: () => updatePubspec(newVersion, buildNumber) },
    { name: 'installer.iss', fn: () => updateInstaller(newVersion) },
    {
      name: 'publish_page/version.json',
      fn: () => updateVersionJson(newVersion),
    },
    { name: 'publish_page/config.js', fn: () => updateConfigJs(newVersion) },
  ];

  const counts = { updated: 0, unchanged: 0, missing: 0, failed: 0 };
  for (const update of updates) {
    try {
      const result = update.fn();
      counts[result]++;
      const label =
        result === 'updated'
          ? 'updated'
          : result === 'unchanged'
          ? 'already current'
          : 'skipped (missing)';
      console.log(`${update.name}: ${label}`);
    } catch (err) {
      counts.failed++;
      console.error(`${update.name}: ERROR: ${err.message}`);
    }
  }

  console.log('');
  console.log(
    `${counts.updated} updated, ${counts.unchanged} already current, ` +
      `${counts.missing} skipped, ${counts.failed} failed`,
  );
  if (counts.failed > 0) process.exitCode = 1;
}

main();
