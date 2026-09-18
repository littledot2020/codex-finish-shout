const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { bundledTracks, bundledAudioPath, syncCompletionAudio, trackFromAudioFile } = require('../audio-settings');

test('all bundled cues include matching, real MP3 and MIDI assets in both packages', () => {
    assert.equal(bundledTracks.length, 3);
    for (const track of bundledTracks) {
        for (const file of [track.mp3, track.midi]) {
            const controls = fs.readFileSync(path.join(__dirname, '..', 'assets', 'music', file));
            const backend = fs.readFileSync(path.join(__dirname, '..', '..', 'codex-finish-shout', 'assets', 'music', file));
            assert.deepEqual(controls, backend, `${file} differs between packages`);
            if (file.endsWith('.mid')) {
                assert.equal(controls.subarray(0, 4).toString(), 'MThd');
                assert.equal(controls.readUInt16BE(10), 1);
                assert.equal(controls.subarray(14, 18).toString(), 'MTrk');
                assert.equal(controls.readUInt32BE(18), controls.length - 22);
            } else {
                assert.equal(controls.subarray(0, 3).toString(), 'ID3');
                assert.ok(controls.length > 20000);
            }
        }
    }
});

test('a new configuration uses packaged audio and requires no external music file', () => {
    const settings = {};
    assert.equal(syncCompletionAudio(settings), true);
    assert.equal(settings.mode, 'audioFile');
    assert.equal(settings.audioFile, 'builtin:soft-chime');
    assert.equal(syncCompletionAudio(settings), false);
});

test('selecting a preset replaces the sound but preserves volume, timings, and other settings', () => {
    const settings = { mode: 'tts', audioFile: 'old.mp3', enabled: false, volume: 28, playback: { mode: 'loop', seconds: 10 } };
    const playback = settings.playback;
    syncCompletionAudio(settings, { preset: 'bright-finish' });
    assert.equal(settings.audioFile, 'builtin:bright-finish');
    assert.equal(settings.mode, 'audioFile');
    assert.equal(settings.enabled, false);
    assert.equal(settings.volume, 28);
    assert.equal(settings.playback, playback);
});

test('backend builtin selections and old extension locations follow the current package after upgrades', () => {
    for (const audioFile of ['builtin:gentle-rise', 'C:\\Users\\name\\.vscode\\extensions\\local-developer.codex-finish-shout-controls-0.9.0\\assets\\music\\gentle-rise.mp3']) {
        const settings = { audioFile };
        syncCompletionAudio(settings);
        assert.equal(settings.audioFile, 'builtin:gentle-rise');
        assert.equal(trackFromAudioFile(settings.audioFile).id, 'gentle-rise');
    }
});

test('existing custom paths, missing custom paths, speech, and beep choices are preserved', () => {
    for (const settings of [
        { mode: 'audioFile', audioFile: 'C:\\My Music\\personal.mp3' },
        { mode: 'audioFile', audioFile: 'missing-personal.mp3' },
        { mode: 'audioFile', audioFile: 'D:\\my-project\\assets\\music\\soft-chime.mp3' },
        { mode: 'audioFile', audioFile: 'D:\\backend-runtime\\assets\\music\\bright-finish.mp3' },
        { mode: 'tts' }, { mode: 'beep' }
    ]) {
        const original = { ...settings };
        assert.equal(syncCompletionAudio(settings, { exists: () => false }), false);
        assert.deepEqual(settings, original);
    }
});

test('an existing custom file with a preset filename is never treated as a bundled selection', () => {
    const settings = { mode: 'audioFile', audioFile: 'D:/my-project/assets/music/soft-chime.mp3' };
    assert.equal(trackFromAudioFile(settings.audioFile), undefined);
    assert.equal(syncCompletionAudio(settings, { exists: () => true }), false);
    assert.equal(settings.audioFile, 'D:/my-project/assets/music/soft-chime.mp3');
});

test('only the missing historical default song migrates, while an existing copy stays selected', () => {
    const oldDefault = path.join(os.homedir(), 'Music', '\u7275\u4e1d\u620f.mp3');
    const present = { audioFile: oldDefault, mode: 'audioFile' };
    assert.equal(syncCompletionAudio(present, { exists: () => true }), false);
    const missing = { ...present };
    assert.equal(syncCompletionAudio(missing, { exists: () => false }), true);
    assert.equal(missing.audioFile, 'builtin:soft-chime');
});

test('custom selection accepts absolute local supported files and ignores blank, relative, remote, and MIDI paths', () => {
    const customFile = path.join(os.tmpdir(), 'my completion music.mp3');
    const settings = {};
    assert.equal(syncCompletionAudio(settings, { preset: 'custom', customFile }), true);
    assert.equal(settings.audioFile, customFile);
    for (const invalid of ['', 'relative.mp3', 'https://example.test/audio.mp3', path.join(os.tmpdir(), 'source.mid')]) {
        const original = { ...settings };
        assert.equal(syncCompletionAudio(settings, { preset: 'custom', customFile: invalid }), false);
        assert.deepEqual(settings, original);
    }
});

test('untrusted preset identifiers cannot escape the music directory', () => {
    assert.throws(() => bundledAudioPath('../arbitrary-file'));
    assert.equal(trackFromAudioFile('builtin:../../arbitrary'), undefined);
});
