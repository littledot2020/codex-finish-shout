const fs = require('fs');
const os = require('os');
const path = require('path');
const bundledTracks = require('./assets/music/catalog.json');

const defaultTrackId = 'soft-chime';
const supportedAudioExtensions = ['mp3', 'wav', 'wma', 'm4a', 'aac'];

function bundledAudioPath(trackId, extensionRoot = __dirname) {
    const track = bundledTracks.find((item) => item.id === trackId);
    if (!track) throw new Error(`Unknown completion sound: ${trackId}`);
    return path.join(extensionRoot, 'assets', 'music', track.mp3);
}

function trackFromAudioFile(audioFile, extensionRoot = __dirname) {
    if (typeof audioFile !== 'string') return undefined;
    const normalized = audioFile.replace(/\\/g, '/').toLowerCase();
    return bundledTracks.find((track) => {
        if (normalized === `builtin:${track.id}`) return true;
        const currentPath = bundledAudioPath(track.id, extensionRoot).replace(/\\/g, '/').toLowerCase();
        if (normalized === currentPath) return true;
        // Only a recognized VS Code extension installation can be migrated.
        // A personal file with the same assets/music basename stays personal.
        const oldExtensionPath = new RegExp('/(?:local-developer|littledot2020)\\.codex-finish-shout-controls-\\d+\\.\\d+\\.\\d+(?:-[^/]+)?/assets/music/' +
            track.mp3.replace('.', '\\.') + '$');
        return oldExtensionPath.test(normalized);
    });
}

function expandAudioPath(value) {
    return String(value || '').replace(/%([^%]+)%/g, (_, name) => process.env[name] || `%${name}%`)
        .replace(/^~(?=$|[\\/])/, os.homedir());
}

function isMissingLegacyDefault(audioFile, exists = fs.existsSync) {
    const expanded = expandAudioPath(audioFile);
    const legacy = path.join(os.homedir(), 'Music', '\u7275\u4e1d\u620f.mp3');
    return expanded && path.resolve(expanded).toLowerCase() === path.resolve(legacy).toLowerCase() && !exists(expanded);
}

function syncCompletionAudio(settings, { preset = '', customFile = '', extensionRoot = __dirname, exists = fs.existsSync } = {}) {
    let selectedFile;
    if (bundledTracks.some((track) => track.id === preset)) {
        selectedFile = `builtin:${preset}`;
    } else if (preset === 'custom') {
        if (typeof customFile !== 'string' || !customFile.trim()) return false;
        const expanded = expandAudioPath(customFile.trim());
        if (!path.isAbsolute(expanded) || !supportedAudioExtensions.includes(path.extname(expanded).slice(1).toLowerCase())) return false;
        // A moved file is kept as the user's selection; the backend handles the
        // configured fallback instead of silently replacing it with a preset.
        selectedFile = path.normalize(expanded);
    } else if (!settings.mode || settings.mode === 'audioFile') {
        const currentTrack = trackFromAudioFile(settings.audioFile, extensionRoot);
        if (currentTrack) selectedFile = `builtin:${currentTrack.id}`;
        else if (!settings.audioFile || isMissingLegacyDefault(settings.audioFile, exists)) {
            selectedFile = `builtin:${defaultTrackId}`;
        }
    }
    if (!selectedFile || (settings.audioFile === selectedFile && settings.mode === 'audioFile')) return false;
    settings.mode = 'audioFile';
    settings.audioFile = selectedFile;
    return true;
}

module.exports = { bundledTracks, defaultTrackId, supportedAudioExtensions, bundledAudioPath,
    trackFromAudioFile, expandAudioPath, isMissingLegacyDefault, syncCompletionAudio };
