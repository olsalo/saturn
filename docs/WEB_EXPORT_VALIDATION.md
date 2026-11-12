# Website export validation — 2026-11-11

Website export uses AV1 first and VP9 as the browser fallback, both in WebM with Opus audio. The compositor renders once. Rust stages `video-av1.webm`, `video-vp9.webm`, `embed.html` and `README.txt`, validates and syncs all four files, then publishes the complete folder under a unique name. A failure or cancellation removes the staged pair. Existing export folders are preserved.

HEVC MP4 retains its prior VideoToolbox Main 10 settings. H.264 VideoToolbox MP4 is a separate compatibility choice.

## Builds and tests

- Frontend production build, six frontend tests and seven launcher tests passed.
- Sixteen Rust tests passed; one existing benchmark was ignored. The new export test rejects incomplete/empty pairs and checks destination naming.
- The full native suite passed Website AV1/VP9, H.264 MP4 and HEVC. Checks include dimensions, audio, duration, cursor shapes/timing, window seams, video/audio endings, MP4 Fast Start, active cancellation and compositor-master cleanup.
- The Website test passed full software video decoding, expected codecs/dimensions/audio-track counts, duration, actual AV1 profile/level declarations, source ordering, front-loaded WebM Cues, monotonic progress, existing-folder protection and cancellation cleanup. Its EBML check inspects direct Segment children so a Cues reference inside SeekHead cannot give a false positive.
- Chromium played the AV1 WebM normally. Marking its source unsupported selected and played VP9; audio decoding was observed and neither path produced a media error.
- The export selector offers Website, HEVC MP4 and H.264 MP4. Its selected label, color and opacity stayed stable through pending saves for window and screen capture. Pending controls stayed disabled while preserving their normal appearance.

Logs are `/tmp/saturn-webm-check.log`, `/tmp/saturn-webm-rust.log`, `/tmp/saturn-webm-final-native.log` and `/tmp/saturn-webm-final-tests.log`. Repeat the paired encoder test with `npm run test:web`; compositor integration is included in `npm run test:native`.

## Real UI detail sample

The retained six-second compositor fixture at `/private/tmp/saturn-border-baseline/corrected-master.mov`, scaled to 2560×1600, produced approximately 195 KiB AV1 WebM and 206 KiB VP9 WebM. These are content-dependent examples, not size guarantees. AV1 uses libaom CRF 32 / CPU-used 6 with screen-content tuning; VP9 uses libvpx CRF 32 / CPU-used 4.

Software-decoded samples at the start, middle and end passed RGB PSNR ≥38 dB, edge PSNR ≥30 dB and zero unexpected white-to-black patches. Both codecs retained all 205 eligible faint window-control arc samples. AV1 measured 45.40–45.91 dB overall and 33.93–34.46 dB at edges; VP9 measured 44.58–45.02 / 33.38–33.83 dB. The AV1 detail measurements used the same encoded video before its final WebM remux. Full video decode is also checked independently for each published Website output.

Repeat the fixture-specific outline check with:

```sh
python3 scripts/verify-web-detail.py master.mov export.webm --controls
```

This comparator uses FFmpeg software decoding: AVFoundation cannot decode AV1 on this test Mac. Logs are `/tmp/saturn-av1-detail.log` and `/tmp/saturn-vp9-detail.log`.

## Distribution and process handling

FFmpeg/ffprobe remain separate LGPL executables with statically linked permissive libaom 3.15.1, libvpx 1.16.0 and Opus 1.6.1. Complete source archives, license/patent notices and build recipes are included under `public/legal`. Runtime dependencies inspected by `otool -L` are macOS system frameworks/libraries. Build-only CMake/pkgconf stay in the ignored target directory. Setup re-verifies executable, probe and source hashes before reuse.

A test exposed Foundation's thread/run-loop-based `waitUntilExit` hanging after an async suspension. The FFmpeg runner now polls termination/cancellation and awaits pipe EOF asynchronously. Corrected paired export and cancellation tests passed.

The existing Saturn app was running, so its bundle was left untouched. Quit it and run `npm run desktop:build` to apply the changes. Intel hardware and Windows/Linux capture/compositing were not tested.
