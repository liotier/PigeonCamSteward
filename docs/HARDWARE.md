# Hardware guidance

Camera selection, USB topology, autofocus, and outdoor deployment notes for
PigeonCamSteward. See [../SPEC.md §10](../SPEC.md#10-documentation-deliverables)
for the source material this expands on.

## Camera selection

- **MJPEG capture, not YUYV**, for 1080p30+ over USB 2.0. Uncompressed YUYV
  at 1080p is bandwidth-capped by the UVC driver to roughly 5 fps on USB
  2.0. This fails *silently* — capture keeps working, just at an
  unannounced low frame rate — and if you're previewing through something
  like OBS while diagnosing, its on-screen FPS counter reports the
  *compositor's* render rate, not the source's actual capture rate, which
  can mask the problem entirely. `pigeoncam-doctor.sh` checks this
  combination (FR17); do not skip it on a new camera.
- Confirm your specific unit's actual supported modes with
  `v4l2-ctl --list-formats-ext -d /dev/videoN` — don't assume a spec sheet;
  firmware and driver quirks vary between units of the same model.
- The reference deployment uses a Logitech Brio 500 on an Intel Sandy
  Bridge–generation host, encoding in software (`libx264`). No hardware
  encode (VAAPI/QSV) is assumed; it may be offered later as an opt-in but
  is never required.

## USB topology

Topology matters more than nominal USB spec compliance.

- **Minimize hub hops to the camera.** A powered hub must sit as the
  *final* hop immediately before the camera to actually help. Placed
  further upstream, with unpowered hubs still between it and the camera, it
  does not reliably fix leaf-device power/negotiation faults — the marginal
  current budget it's meant to correct is consumed at the hop(s) closest to
  the device, not at the chain's root.
- **Active extension cables are not a substitute for a powered hub.** They
  enumerate as their own hub-like device in `lsusb -t`/`dmesg` output and
  introduce another negotiation point, not extra power budget where the
  camera actually needs it.
- Diagnose with `dmesg -T | grep -iE 'usb|uvc'`. Three distinct failure
  signatures are worth telling apart, since they point at different (though
  possibly related) causes:

  | Signature | What it looks like | Likely meaning |
  |---|---|---|
  | Hard disconnect | `USB disconnect` + a new device number assigned shortly after | Device fully dropped off the bus and re-enumerated |
  | Soft freeze | Repeated `retire_capture_urb: N callbacks suppressed`, no disconnect line | Device stays enumerated but isochronous capture is degrading; often recoverable only by a device-level reset (`pigeoncam-usb-reset.sh`, FR7b), not a process restart |
  | Wedged post-(re)enumeration | `Failed to set UVC probe control : -32` right after a `Found UVC ... device` line | Device came back from a disconnect/reset in a state where UVC negotiation itself fails; sometimes self-clears on the *next* open attempt, sometimes needs a further physical reseat |

  A cascade of `USB disconnect` lines across multiple hub tiers
  simultaneously, triggered by a deliberate physical reconnect (unplugging
  a hub to rewire the chain, for instance), is expected noise from the
  intervention itself — don't read it as evidence of an ongoing fault.
  Only disconnects with no corresponding physical action behind them are
  diagnostically meaningful.

## Autofocus

A genuinely counterintuitive point worth stating plainly: for a static
subject at a fixed camera distance, locking focus (via the UVC
`focus_automatic_continuous`/`focus_absolute` controls, settable through
`v4l2-ctl` — the same pattern as locking exposure) removes autofocus
hunting as a variable. **But** if the subject's depth will drift gradually
over the deployment — a nest's contents building up under a sitting bird,
young growing and changing the effective subject plane over several weeks —
a fixed focus value tuned on day one can go stale by week three with nobody
present to re-tune it.

In that case, leaving continuous autofocus enabled and accepting occasional
hunting/soft frames is the more robust default for an unattended
multi-week run, even though it looks less "correct" than a locked value.
Pick based on your actual subject, not a general preference for stability.

Consumer autofocus algorithms on webcams marketed for video calls are
commonly weighted toward face-like features (a well-defined eye against
lighter surrounding tissue is a strong contrast target); expect hunting
when higher-contrast foreground clutter (branches, enclosure bars, glass
reflections) competes with a lower-contrast subject for the algorithm's
attention. Don't mistake this for a minimum-focus-distance limit or a
compression artifact — compare two frames taken moments apart at
otherwise-identical settings; if sharpness varies between them, it's a
focus decision, not the codec.

## Outdoor deployment

Weatherproofing consumer USB electronics that were never rated for it:
condensation and heat matter even under a roof that blocks rain directly,
since neither the camera nor any auxiliary electronics (e.g. a
supplementary light) are IP-rated, and both still see full ambient humidity
and temperature swings.

A device can also fail wedged-but-enumerated rather than disconnected (the
soft-freeze or post-reset-negotiation-failure signatures in the table
above) and needs an actual device-level reset, not a process restart, to
recover — see [FR7b in SPEC.md](../SPEC.md#52-health-watchdog).
