# Completion audio assets

The `music/` directory bundles three original completion cues: **Soft chime**, **Bright finish**, and **Gentle rise**. Each includes a synthesized MP3 recording and matching MIDI source. Playback uses MP3 and does not require a MIDI synthesizer. See `music/LICENSE.txt` for redistribution terms.

Choose a bundled cue from the Controls extension's music button, or run from the plugin root:

```powershell
.\scripts\configure.ps1 SetBuiltinAudio -Sound bright-finish
```

To play your own local file after confirmed project completion, run:

```powershell
.\scripts\configure.ps1 SetAudio -AudioFile "C:\path\to\your-song.mp3"
```

Supported formats are WAV, MP3, WMA, M4A, and AAC when the corresponding
Windows media codec is available.
