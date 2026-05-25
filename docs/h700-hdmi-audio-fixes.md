# H616/H700 Audio Fixes (Allwinner RG35XX Pro)

**Platform:** Allwinner H616/H700 (sun50i-h616 family)  
**Kernel:** mainline 7.0.x with Armbian sunxi-7.0 audio patches  
**Display bridge:** Synopsys dw-hdmi (sun8i variant)  
**HDMI audio path:** app → ALSA → AHUB DMA → I2S TDM1 → dw-hdmi frame composer → HDMI stream  
**Internal codec path:** app → ALSA → sun4i-codec DMA → H616 internal I2S → DAC → speaker/headphone  
**Symptoms fixed:** HDMI audio completely silent, no HDMI ALSA card, hotplug
routing not switching away from handheld speakers, Rescan-HDMI-Audio
blanking the display, internal speaker/headphone audio playing at half speed,
44.1 kHz content playing at wrong pitch.

---

## Background — the audio path on H616/H700

The H616/H700 does not feed audio to HDMI through a simple I2S wire.
It routes audio through a dedicated **AHUB (Audio Hub)** block that
multiplexes multiple I2S/TDM streams, then connects TDM channel **#1**
(index 1, `SUNXI_AHUB_HDMI_ID`) internally to the Synopsys **dw-hdmi**
frame composer's audio input. The display pipeline and the audio
pipeline are thus largely independent at the hardware level; both must
be configured correctly for audio to reach the HDMI sink.

---

## Fix 1 — Import Armbian sunxi_v2 AHUB driver (no HDMI card without it)

**Root cause:** Mainline Linux does not have a driver for the Allwinner
sunxi_v2 AHUB block used on H616/H700. Without it, no HDMI ALSA card
registers at boot and there is simply nowhere to route audio.

**Fix:** Apply the Armbian sunxi-7.0 AHUB patch series verbatim:

- `0224-0701-armbian-h616-hdmi-audio.patch` — imports the full
  `sound/soc/sunxi_v2/` driver tree and adds the H616 DT nodes
  (`ahub_dam_plat`, `ahub1_plat`, `ahub1_mach`) to the SoC DTSI.
- `0225-0702-h616-digital-audio-node.patch` — companion patch adding
  `ahub_dam_mach`.

**DTS:** Enable the AHUB nodes for your board's `.dts`:
```dts
&ahub_dam_plat { status = "okay"; };
&ahub1_plat    { status = "okay"; };
&ahub1_mach    { status = "okay"; };
```

**Kernel config:**
```
CONFIG_SND_SOC_SUNXI_AHUB=y
```
(auto-selects `SND_SOC_SUNXI_AHUB_MACH` and `SND_SOC_SUNXI_AHUB_DAM`
via Kconfig.)

**Note:** Drop any older `dts-Enable-hdmi-sound.patch` style imports
that add BSP-compat-string nodes — their compat strings have no driver
in the mainline tree and the conflicting node names will cause DT
compile errors or silent no-ops.

After this, an HDMI ALSA card registers (`aplay -l` shows a card) but
audio is still silent on real hardware. Continue to Fix 2.

---

## Fix 2 — AHUB → dw-hdmi routing registers not programmed

**Root cause:** The Armbian sunxi_v2 port correctly programs the
per-TDM TX route registers but omits three additional register writes
that the Allwinner BSP (`orangepi-xunlong/linux-orangepi`) performs
when the TDM in use is the HDMI one (`tdm_num == 1`).

Without these, the AHUB sends valid I2S data on TDM1 SDO0 but none of
it reaches the dw-hdmi audio block.

**What the BSP does that the Armbian port does not:**

1. **Enable all 4 SDO output lanes** (`SDO0`–`SDO3`) on TDM1, not just
   the single lane selected by `tx_pin`. The dw-hdmi audio block
   samples multiple lanes for multi-channel / HBR layout support.
   ```c
   regmap_update_bits(regmap, SUNXI_AHUB_I2S_CTL(tdm_num),
                      0xF << I2S_CTL_SDO0_EN,
                      0xF << I2S_CTL_SDO0_EN);
   ```

2. **Set `HDMI_SRC_SEL` in `SUNXI_AHUB_CTL`** so the HDMI clock is
   sourced from the AHUB rather than from an external pin.
   ```c
   regmap_update_bits(regmap, SUNXI_AHUB_CTL,
                      0x1 << HDMI_SRC_SEL,
                      0x1 << HDMI_SRC_SEL);
   ```

3. **Write the BSP channel-slot map** `0x10` to
   `SUNXI_AHUB_I2S_OUT_CHMAP0(tdm_num, 0)`.
   ```c
   regmap_write(regmap, SUNXI_AHUB_I2S_OUT_CHMAP0(tdm_num, 0), 0x10);
   ```

These three writes only apply when `tdm_num == SUNXI_AHUB_HDMI_ID`
(i.e. `== 1`). The fix is a small addition to
`sunxi_ahub_dai_tx_route()` in `sound/soc/sunxi_v2/snd_sunxi_ahub.c`.

**Sources (BSP):**
- `sound/soc/sunxi/sunxi_ahub.c:557` — `HDMI_SRC_SEL`
- `sound/soc/sunxi/sunxi_ahub_daudio.c:76–90` — SDO0–3 enable
- `sound/soc/sunxi/sunxi_ahub_daudio.c:485–489` — CH0MAP0

After this fix, audio data reaches dw-hdmi on most sinks. On sinks
where EDID is readable, audio should now work. On H616/H700 with most
monitors it is still silent — continue to Fix 3.

---

## Fix 3 — dw-hdmi stuck in DVI mode (the real silence-killer)

**Root cause:** The Synopsys dw-hdmi frame composer has a single bit
in `FC_INVIDCONF` (`DVI_MODEZ`, bit 3) that controls whether it is in
**HDMI mode** (audio packets transmitted) or **DVI mode** (audio
packets silently dropped at the frame composer, regardless of how
everything upstream is configured). When this bit is 0 (DVI mode), no
audio ever reaches the sink.

`dw_hdmi_setup()` sets this bit based on `sink_is_hdmi`, which comes
from `drm_detect_hdmi_monitor()` → EDID. On H616/H700, the AHUB driver
binding corrupts the dw-hdmi's **internal DDC I2C master** as a side
effect, causing all subsequent EDID reads to return `EAGAIN`.
`sink_is_hdmi` remains `false`, `FC_INVIDCONF` is left in DVI mode,
and the controller silently drops every audio packet.

This is why you can confirm with `amixer` or PipeWire that audio is
being sent, verify TDM signals are correct with a logic analyzer, and
still hear nothing from the monitor.

**Fix:** In `dw_hdmi_audio_enable()`, force `FC_INVIDCONF` into HDMI
mode unconditionally. Any caller of `audio_enable` is by definition
requesting audio over HDMI — a pure DVI sink would never trigger this
code path, so the assumption is safe:

```c
void dw_hdmi_audio_enable(struct dw_hdmi *hdmi)
{
    unsigned long flags;
    spin_lock_irqsave(&hdmi->audio_lock, flags);
    hdmi->audio_enable = true;
    if (hdmi->enable_audio)
        hdmi->enable_audio(hdmi);

    /* Force HDMI mode so audio packets are not dropped.
     * sink_is_hdmi may be false if EDID read failed (H616/H700 AHUB
     * corrupts the internal DDC master); audio_enable implies HDMI. */
    hdmi_modb(hdmi, HDMI_FC_INVIDCONF_DVI_MODEZ_HDMI_MODE,
              HDMI_FC_INVIDCONF_DVI_MODEZ_MASK,
              HDMI_FC_INVIDCONF);

    spin_unlock_irqrestore(&hdmi->audio_lock, flags);
}
```

**Verified live 2026-05-15:** Without this fix, `FC_INVIDCONF` reads
`0x10` (DVI mode). After the fix, the bit is set correctly and PipeWire
HDMI sink plays through monitor speakers.

---

## Fix 4 — HDMI hotplug chain never fires (udev rule missing + pgrep bug)

**Root cause (two independent bugs):**

1. **Missing udev rule.** The `hdmi_sense` script, systemd `.path`
   watcher, and `handle-hdmi-hotplug` service were all present but the
   udev rule that calls `hdmi_sense` on DRM card add/change events was
   never installed. Without it, plugging/unplugging the cable never
   populated `/run/hdmi-status.last`, and the `.path` watcher never
   fired.

2. **`pgrep -x emulationstation` always fails.** `procps-ng pgrep`
   refuses any pattern longer than the 15-character kernel `comm` field
   limit (`"pattern that searches for process name longer than 15
   characters will result in zero matches"`). `emulationstation` is 17
   characters, so the guard in `handle-hdmi-hotplug` always tripped and
   the script silently exited 0 on every hotplug event without doing
   anything.

**Fixes:**

1. Install a udev rule (`/etc/udev/rules.d/99-hdmi.rules`) that fires
   `hdmi_sense` on DRM connector events:
   ```
   ACTION=="add|change", SUBSYSTEM=="drm", RUN+="/usr/bin/hdmi_sense"
   ```

2. Replace `pgrep -x emulationstation` with `pidof emulationstation`
   everywhere in the hotplug chain. `pidof` matches the executable
   basename without a comm-length cap.

**Note for ROCKNIX:** ROCKNIX's vendored scripts use the same `pgrep -x
emulationstation` pattern. It works there because their `busybox pgrep`
does not enforce the 15-char limit. Any downstream that uses
`procps-ng` (rather than busybox) will hit this silently.

---

## Fix 5 — AHUB sink name not matched by hdmi_sense (audio never switches)

**Root cause:** The `hdmi_sense` PipeWire sink-detection logic used a
case-sensitive regex `/hdmi/` to find the HDMI sink. The Allwinner
sunxi_v2 AHUB driver registers its ALSA card as:

```
alsa_output._sys_devices_platform_soc_soc_ahub1_mach_sound_card1.stereo-fallback
```

There is no `"hdmi"` anywhere in that string. The positive match fails,
`DEFAULT_SINK` is set to `""`, and the script falls through to the
"no HDMI sink" branch — which sets the handheld analog speakers as the
default sink on every boot, even with HDMI connected and working.

**Fix:** Update both the positive and negative awk matches in
`hdmi_sense` to use `tolower()` and accept either `"hdmi"` (any case)
**or** `"ahub1_mach"` as a valid HDMI sink indicator:

```awk
# Before (case-sensitive, misses AHUB sink):
$0 ~ /hdmi/ { ... }

# After (case-insensitive, matches both naming conventions):
tolower($0) ~ /hdmi|ahub1_mach/ { ... }
```

After this fix, `hdmi_sense` correctly detects the AHUB HDMI sink and
migrates the default output on cable connect.

---

---

## Fix 6 — HDMI audio plays at ~80–85% speed (wrong PLL rate)

**Root cause:** A bug in `ccu_nm_set_rate()` in the sunxi-ng CCU driver
(`drivers/clk/sunxi-ng/ccu_nm.c`) causes the `pll-audio-hs` clock to
never lock to the correct audio frequency, leaving it at whatever rate
U-Boot set (688 MHz on RG35XX Pro). At 688 MHz the audio-hub ends up at
43 MHz and audio-codec-1x at ~98.286 MHz — close to the target 98.304 MHz
but not exact, producing audio that plays at approximately 80–85% of
normal speed.

### The three-layer failure

**Layer 1 — wrong DTS clock binding.**
The Armbian AHUB patch's `clk_pll_audio_4x` DT reference used
`CLK_AUDIO_CODEC_4X` (index 92, the `audio-codec-4x` post-divider clock).
`audio-codec-4x` is **not** in `audio-hub`'s parent MUX table — the MUX
accepts only `{pll-audio-1x, pll-audio-2x, pll-audio-4x, pll-audio-hs}`.
`clk_set_parent(audio-hub, audio-codec-4x)` always returned `-EINVAL`
silently.

**Fix:** Bind `clk_pll_audio_4x` to index `20` (`pll-audio-4x`,
`CLK_PLL_AUDIO_4X` in `ccu-sun50i-h616.h`), which **is** in the MUX.
Note: `CLK_PLL_AUDIO_4X=20` is only in the internal driver header; the
public `include/dt-bindings/clock/sun50i-h616-ccu.h` does not export it.
Use the raw index:

```dts
clocks = <&ccu CLK_AUDIO_CODEC_1X>,
         <&ccu 20>,               /* pll-audio-4x (index 20 in ccu-sun50i-h616.h) */
         <&ccu CLK_AUDIO_HUB>,
         <&ccu CLK_BUS_AUDIO_HUB>;
clock-names = "clk_pll_audio", "clk_pll_audio_4x",
              "clk_audio_hub", "clk_bus_audio_hub";
```

**Layer 2 — `sunxi_ahub_dai_set_pll` programmed the wrong clock.**
The AHUB driver's `set_pll` function called `clk_set_rate(clk_pll, ...)` where
`clk_pll` = `audio-codec-1x`. `audio-codec-1x` has `CLK_SET_RATE_PARENT`
and its parent chain reaches `pll-audio-hs` through several dividers;
`clk_set_rate` propagated the wrong M value (7) giving ≈98.286 MHz instead
of 98.304 MHz. Also called `clk_set_rate(clk_module, 0)` which switched
audio-hub back to the minimum-rate parent.

**Fix:** Change `set_pll` to directly rate `clk_pllx4` (`pll-audio-4x`),
reparent `audio-hub` to it, then set the module clock to `freq_in`. The
`pll-audio-4x → pll-audio-hs` chain propagates correctly with
`CLK_SET_RATE_PARENT`.

**Layer 3 (root cause) — SDM table stores output rates, not VCO rates.**
`ccu_nm_set_rate()` multiplies the requested rate by `fixed_post_div`
**before** comparing against the SDM table:

```c
/* ccu_nm.c */
if (nm->common.features & CCU_FEATURE_FIXED_POSTDIV)
    rate = rate * nm->fixed_post_div;   /* ×2 — BEFORE the SDM lookup */

if (ccu_sdm_helper_has_rate(&nm->common, &nm->sdm, rate)) {
    /* enabled only if table entry matches the pre-multiplied rate */
}
```

`pll-audio-hs` has `fixed_post_div = 2`, so requesting 98304000 Hz causes
the comparison to run against **196608000**. But the SDM table in
`ccu-sun50i-h616.c` stores output rates:

```c
/* WRONG — stores output rates */
static struct ccu_sdm_setting pll_audio_sdm_table[] = {
    { .rate = 90316800,  .pattern = 0xc001288d, .m = 3, .n = 22 },
    { .rate = 98304000,  .pattern = 0xc001eb85, .m = 5, .n = 40 },
};
```

`ccu_sdm_helper_has_rate(196608000)` finds no match → SDM is disabled →
integer-only N/M calculation → PLL fails to lock → `ccu_helper_wait_for_lock`
WARN_ON fires at ~500 ms → function returns 0 anyway → PLL stays at U-Boot
value (688 MHz).

`ccu_nm_recalc_rate()` already divides the table rate by `fixed_post_div`
when returning the observable clock rate, so the fix is simply to store
**VCO rates** (output × `fixed_post_div` = output × 2) in the table:

```c
/* CORRECT — stores VCO rates */
static struct ccu_sdm_setting pll_audio_sdm_table[] = {
    { .rate = 180633600, .pattern = 0xc001288d, .m = 3, .n = 22 },
    { .rate = 196608000, .pattern = 0xc001eb85, .m = 5, .n = 40 },
};
```

After this fix: `ccu_sdm_helper_has_rate(196608000)` hits → SDM enabled →
pattern 0xc001eb85 written → PLL locks to 196608000 Hz VCO / 2 = 98304000 Hz
output → audio-hub clocked at 98304000 Hz → audio plays at correct speed.

**Verification:**
```bash
# Before fix:
cat /sys/kernel/debug/clk/pll-audio-hs/clk_rate  # → 688000000 (U-Boot value)
dmesg | grep ccu_helper                           # → WARNING: wait_for_lock timeout

# After fix:
cat /sys/kernel/debug/clk/pll-audio-hs/clk_rate  # → 98304000
dmesg | grep ccu_helper                           # (silent)
```

**Note for ROCKNIX / upstream:** This SDM table bug affects all mainline
kernels on H616/H700 using `ccu-sun50i-h616.c`. The WARN_ON from
`ccu_helper_wait_for_lock` in `ccu_nm_set_rate` is the diagnostic
fingerprint. Any board that boots into U-Boot with pll-audio-hs at a
non-audio rate (e.g. 688 MHz, 600 MHz) and never hears audio play at
the right pitch has this problem.

---

---

## Fix 7 — Internal codec plays at half speed (H616 fixed BCLK/MCLK ratio)

**Affects:** Speaker and 3.5 mm headphone output on all H616/H700 devices
(RG35XX Pro, RG34XX SP, RG28XX, RG40XX, RGCubeXX, etc.). HDMI and USB-C
audio are unaffected.

**Root cause:** The H616 internal codec I2S interface generates BCLK at a
hardware-fixed ratio of **MCLK/16**, and always uses **32-bit I2S slots**
(64 BCLK pulses per LRCLK period) regardless of sample format. The legacy
`sun4i_codec_get_mod_freq()` returns 24576000 Hz for any 48 kHz rate:

```
BCLK  = MCLK / 16 = 24576000 / 16 = 1536000 Hz
LRCLK = BCLK / 64 = 1536000 / 64  = 24000 Hz   ← half of 48000 Hz
```

Both S16_LE and S32_LE are affected equally because the slot width is
always 32 bits in hardware regardless of the logical sample width.

The half-speed symptom appeared after AHUB DTS nodes were enabled, which
caused PipeWire to negotiate S32_LE with the internal codec (exposing the
latent mismatch). However the bug existed for S16_LE too — it was just
never triggered because PipeWire defaulted to S16_LE before AHUB was
present and the SDM table bug (Fix 6) masked the audio entirely.

**Measured:** `hw_ptr` advanced ~24 120 frames/s (≈ 0.5×) for both S16_LE
and S32_LE at 48 kHz before the fix; 48 000 frames/s after.

**Fix:** Add `mclk_mult` to `struct sun4i_codec` and precompute it in
`sun4i_codec_probe()` from the per-chip quirks:

```c
/* In struct sun4i_codec: */
u32 mclk_mult;  /* MCLK = rate * mclk_mult; 0 → use get_mod_freq() */

/* New quirk fields in struct sun4i_codec_quirks: */
u8 fixed_bclk_div;   /* hardware BCLK = MCLK / fixed_bclk_div */
u8 i2s_slot_width;   /* physical I2S slot width in bits (0 → use params_physical_width) */

/* In sun4i_codec_probe(), after quirks = of_device_get_match_data(): */
if (quirks->fixed_bclk_div) {
    unsigned int sw = quirks->i2s_slot_width ?: 16;
    scodec->mclk_mult = sw * 2 * quirks->fixed_bclk_div;
}

/* H616 quirks entry: */
.fixed_bclk_div = 16,
.i2s_slot_width = 32,
/* → mclk_mult = 32 × 2 × 16 = 1024 */

/* In sun4i_codec_hw_params(), replacing sun4i_codec_get_mod_freq(): */
if (scodec->mclk_mult) {
    clk_freq = (unsigned long)params_rate(params) * scodec->mclk_mult;
} else {
    clk_freq = sun4i_codec_get_mod_freq(params);
    if (!clk_freq)
        return -EINVAL;
}
```

**MCLK values after fix:**

| Rate   | MCLK = rate × 1024 | PLL parent         |
|--------|--------------------|--------------------|
| 48 kHz | 49 152 000 Hz      | pll-audio-2x       |
| 44.1 kHz | 45 158 400 Hz   | pll-audio-2x (44.1)|

Both are reachable from `audio-codec-1x`'s parent MUX via `CLK_SET_RATE_PARENT`.
No change to behaviour for any chip that does not set `fixed_bclk_div`.

**Patch:** `soc/allwinner-h700/mainline/linux/patches/0228-sun4i-codec-h616-bclk-mclk-ratio.patch`

---

## Fix 8 — 44.1 kHz content sounds slightly fast (PipeWire resampling to 48 kHz)

**Symptoms:** 44.1 kHz audio files play at the correct speed overall (the
half-speed bug is gone after Fix 7) but sound a subtle ~8.8% fast or pitch-shifted.

**Root cause:** PipeWire's default `default.clock.allowed-rates = [ 48000 ]`
means it resamples **all** content to 48 kHz before sending it to the ALSA
device, regardless of the source sample rate. The kernel (after Fix 7) runs
the hardware at 48 kHz with `MCLK = 49152000 Hz` — technically correct, but
the SRC introduces the off-pitch perception.

**Fix:** Add a PipeWire drop-in that enables 44.1 kHz as an allowed hardware
rate. PipeWire then switches the hardware clock when the source is 44.1 kHz,
avoiding SRC entirely. The kernel's `rate × 1024` MCLK formula handles both
rates correctly (44100 × 1024 = 45158400 Hz, reachable on the 44.1 kHz PLL chain).

```
# /etc/pipewire/pipewire.conf.d/50-panicos-rates.conf
context.properties = {
    default.clock.allowed-rates = [ 44100 48000 ]
}
```

**Overlay location:** `flavors/launcher/rootfs-overlay/etc/pipewire/pipewire.conf.d/50-panicos-rates.conf`

---

## Fix 9 — USB audio devices don't enumerate (USB-C always in peripheral mode)

**Affects:** Any USB audio interface or USB-C headphones connected to the
USB-C port. Symptom: device never appears in `aplay -l` or as a PipeWire
sink; `lsusb` shows only root hubs; `dmesg` is silent on plug.

**Root cause:** The `sun4i-usb-phy` OTG driver on H616/H700 shares `phy0`
between the MUSB controller (peripheral) and the EHCI host controller.
Routing is determined by the ID pin GPIO (`usb0_id_det-gpios`):

- GPIO HIGH → peripheral mode (phy0 → MUSB, VBUS off, EHCI disabled)
- GPIO LOW  → host mode (phy0 → EHCI, VBUS on)

The RG35XX Pro's USB-C port does **not** have a traditional Micro-USB ID pin.
Role switching is handled by the AXP717 PMIC's CC controller — but the AXP717
USB-C role-switch functionality is **not yet described by the DTS binding**
(see comment in upstream DTS). As a result, the ID GPIO (PI4) never goes LOW,
the OTG scan always sees `id_det = 1`, and the port permanently stays in
peripheral mode. USB audio interfaces, USB-C headphones, USB storage, and
gamepads connected to the USB-C port all fail to enumerate.

The logic in `sun4i_usb_phy0_get_id_det()`:

```c
case USB_DR_MODE_OTG:
    if (data->id_det_gpio)
        return gpiod_get_value_cansleep(data->id_det_gpio);  /* always 1 */
    else
        return 1; /* Fallback to peripheral mode */
case USB_DR_MODE_HOST:
    return 0;  /* ← always host, always routes phy0 to EHCI */
```

**Fix:** Change `dr_mode = "otg"` to `dr_mode = "host"` in the board DTS
and remove the now-unused `usb0_id_det-gpios`. Keep `usb0_vbus-supply` so
the PI16 GPIO regulator enables VBUS unconditionally on boot.

```dts
/* WRONG — AXP717 CC not in DTS binding, PI4 never fires, always peripheral */
&usbotg {
    dr_mode = "otg";
    status = "okay";
};
&usbphy {
    usb0_id_det-gpios = <&pio 8 4 (GPIO_ACTIVE_LOW | GPIO_PULL_UP)>;
    usb0_vbus_power-supply = <&usb_power>;
    usb0_vbus-supply = <&reg_usb0_vbus>;
    status = "okay";
};

/* CORRECT — phy0 always routes to EHCI, VBUS always on */
&usbotg {
    dr_mode = "host";
    status = "okay";
};
&usbphy {
    usb0_vbus_power-supply = <&usb_power>;
    usb0_vbus-supply = <&reg_usb0_vbus>;
    status = "okay";
};
```

After the fix: `usb0-vbus` regulator shows `enabled` at boot, MUSB reports
`a_idle` (host idle), and any USB device plugged into the USB-C port
enumerates immediately on the EHCI bus (`Bus 001`).

**Patch:** `soc/allwinner-h700/mainline/linux/patches/0216-0152-rg35xx-2024-enable-usb-otg.patch`

**Important for anyone applying our audio patches:** Fixes 1–8 add AHUB
DTS nodes, which cause PipeWire to negotiate S32_LE with the internal codec
and push USB audio to attempt enumeration. If you apply our audio patches
without this USB host fix, USB audio devices will silently fail to appear —
not because of a missing driver (`snd-usb-audio` is built-in) but because
phy0 is stuck in peripheral mode and the EHCI host never receives power.

---

## Summary — Checklist for H616/H700 Audio

### HDMI audio

| # | What | How |
|---|------|-----|
| 1 | AHUB driver | Apply Armbian `0701`+`0702` patches; enable `CONFIG_SND_SOC_SUNXI_AHUB=y`; enable DT nodes in board `.dts` |
| 2 | AHUB → dw-hdmi register writes | Patch `sunxi_ahub_dai_tx_route()`: enable all 4 SDO lanes, set `HDMI_SRC_SEL`, write `CHMAP0=0x10` when `tdm_num==1` |
| 3 | dw-hdmi stuck in DVI mode | Patch `dw_hdmi_audio_enable()`: force `FC_INVIDCONF` HDMI mode bit unconditionally |
| 4 | Hotplug chain never fires | Install udev rule for DRM events; replace `pgrep -x emulationstation` with `pidof` in hotplug scripts |
| 5 | AHUB sink name not matched | Update `hdmi_sense` to match `ahub1_mach` (case-insensitive) in addition to `hdmi` |
| 6 | HDMI audio plays at ~80–85% speed | Fix `pll_audio_sdm_table` in `ccu-sun50i-h616.c`: use VCO rates (×2); fix `clk_pll_audio_4x` DTS to bind to index 20; fix `set_pll` to rate `pll-audio-4x` directly |

Fixes 1–3 are kernel-level and required for any HDMI audio at all. Fix 4 is
required for automatic routing on cable connect/disconnect. Fix 5 is
required for `hdmi_sense` to actually switch the default sink. Fix 6 is
required for HDMI audio to play at the correct pitch/speed.

### Internal codec audio (speaker / 3.5 mm headphone)

| # | What | How |
|---|------|-----|
| 6 | PLL doesn't lock (shared with HDMI) | Same SDM table fix as HDMI Fix 6 — required for both paths |
| 7 | Internal audio plays at half speed | Add `fixed_bclk_div=16`, `i2s_slot_width=32` to `sun50i_h616_codec_quirks`; precompute `mclk_mult=1024` in probe; use `rate × mclk_mult` in `hw_params` |
| 8 | 44.1 kHz content sounds fast | Add `/etc/pipewire/pipewire.conf.d/50-panicos-rates.conf` with `default.clock.allowed-rates = [ 44100 48000 ]` |

### USB audio (USB-C port)

| # | What | How |
|---|------|-----|
| 9 | USB devices never enumerate (peripheral mode) | Change `dr_mode = "otg"` → `"host"` in board DTS; remove `usb0_id_det-gpios`; keep `usb0_vbus-supply` |

**Warning:** If you apply Fixes 1–8 without Fix 9, USB audio devices will
appear to be missing a driver but the real cause is phy0 permanently stuck
in peripheral mode. Fix 9 is a DTS-only change — no kernel rebuild needed,
just recompile the DTB and update `dtb.img` on the boot partition.

---

## Patch locations (PanicOS tree)

```
soc/allwinner-h700/mainline/linux/patches/
  0216-0152-rg35xx-2024-enable-usb-otg.patch             # Fix 9 (USB always-host)
  0221-fix-h616-pll-audio-hs-sdm-table-vco-rates.patch  # Fix 6 (SDM table VCO rates)
  0224-0701-armbian-h616-hdmi-audio.patch                # Fix 1 (Armbian import)
  0225-0702-h616-digital-audio-node.patch                # Fix 1 (companion)
  0226-sunxi_v2-ahub-hdmi-routing-fix.patch              # Fix 2 (AHUB routing)
  0227-dw-hdmi-force-hdmi-mode-on-audio-enable.patch     # Fix 3 (DVI mode)
  0228-sun4i-codec-h616-bclk-mclk-ratio.patch            # Fix 7 (internal codec half-speed)

flavors/launcher/rootfs-overlay/
  etc/pipewire/pipewire.conf.d/50-panicos-rates.conf    # Fix 8 (44.1 kHz passthrough)
```
