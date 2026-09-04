# Mic Deck

A macOS menu bar app for controlling the audio input.

It came out of a concrete problem: the gain on a Shure MV7 kept creeping up on
its own during calls, and the vendor software offered no way to stop it.

## Features

- **Prominent mute button** with the global shortcut Control+Option+M. Mute is
  applied at the driver level, so every program hears silence at once and you
  never have to mute inside each call.
- **Gain lock.** Any program that changes the input gain has its change
  reverted. The target is stored per device.
- **Blocked-change log** with the time and which programs were capturing audio
  at that moment. This is what identifies the culprit. It is also written to
  `~/Library/Logs/MicDeck.log`.
- **Level meter** with peak hold and a clip marker. Can be switched off.
- Gain slider in percent and dB, input switching, and open at login.

## Build

```
./build.sh                  # installs to ~/Applications
./build.sh /some/other/path
```

Requires the Xcode command line tools. The bundle is ad-hoc signed, so on
another machine macOS will block the first launch and you have to allow it
under Privacy & Security.

## Decisions that came from measurement, not guesswork

**The lock target is the settled value, not the requested one.** The MV7 only
accepts steps of about 3%: asking for 0.67 yields 0.6944. Storing the request as
the target created an infinite loop, because the lock would see a mismatch
forever. After writing, the app reads the value back and that is what becomes
the target. Reading immediately after the write already returns the settled
value, which was verified before relying on it.

**Echo detection by history, not by flag.** The CoreAudio notification arrives
asynchronously. A boolean flag raised before the write and lowered after it is
already back to normal by the time the notification lands, so the app's own
writes were classified as external changes. The app instead keeps the values it
wrote over the last 1.5 seconds, both requested and settled, and ignores
notifications that match them. Without this, dragging the slider produced a
flood of false positives.

**Writes go to a single element.** Writing to the master element and to the
channels fired two notifications and duplicated every log entry.

**The app excludes itself from the culprit list.** The meter holds the input
open while the menu is open, so the app itself showed up as responsible.

**Private aggregates are filtered out.** When an app opens the input, CoreAudio
creates a `CADefaultDeviceAggregate-<pid>-0` device that appeared alongside the
real microphones. It is hidden by the private flag in its aggregate
composition, not by matching its name.

## Limitations

The orange microphone indicator appears while the meter runs. macOS enforces
that for any audio capture and there is no way around it. Switching the meter
off in the menu removes the indicator.

The lock acts on the macOS side. It does not prevent adjustments made on the
microphone's own touch panel, nor the MV7's auto level mode, both of which act
inside the hardware. To leave that mode, hold Mute on the microphone for two
seconds.

## License

MIT. See [LICENSE](LICENSE).
