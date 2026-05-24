# H616/H700 HDMI Audio Fixes (Allwinner RG35XX Pro)

**Platform:** Allwinner H616/H700 (sun50i-h616 family)  
**Kernel:** mainline 7.0.x with Armbian sunxi-7.0 audio patches  
**Display bridge:** Synopsys dw-hdmi (sun8i variant)  
**Audio path:** app → ALSA → AHUB DMA → I2S TDM1 → dw-hdmi frame composer → HDMI stream  
**Symptoms fixed:** HDMI audio completely silent, no HDMI ALSA card, hotplug
routing not switching away from handheld speakers, Rescan-HDMI-Audio
blanking the display.

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

## Summary — Checklist for H616/H700 HDMI Audio

| # | What | How |
|---|------|-----|
| 1 | AHUB driver | Apply Armbian `0701`+`0702` patches; enable `CONFIG_SND_SOC_SUNXI_AHUB=y`; enable DT nodes in board `.dts` |
| 2 | AHUB → dw-hdmi register writes | Patch `sunxi_ahub_dai_tx_route()`: enable all 4 SDO lanes, set `HDMI_SRC_SEL`, write `CHMAP0=0x10` when `tdm_num==1` |
| 3 | dw-hdmi stuck in DVI mode | Patch `dw_hdmi_audio_enable()`: force `FC_INVIDCONF` HDMI mode bit unconditionally |
| 4 | Hotplug chain never fires | Install udev rule for DRM events; replace `pgrep -x emulationstation` with `pidof` in hotplug scripts |
| 5 | AHUB sink name not matched | Update `hdmi_sense` to match `ahub1_mach` (case-insensitive) in addition to `hdmi` |
| 6 | Audio plays at ~80–85% speed | Fix `pll_audio_sdm_table` in `ccu-sun50i-h616.c`: use VCO rates (×2); fix `clk_pll_audio_4x` DTS to bind to index 20; fix `set_pll` to rate `pll-audio-4x` directly |

Fixes 1–3 are kernel-level and required for any audio at all. Fix 4 is
required for automatic routing on cable connect/disconnect. Fix 5 is
required for `hdmi_sense` to actually switch the default sink. Fix 6 is
required for audio to play at the correct pitch/speed.

---

## Patch locations (PanicOS tree)

```
soc/allwinner-h700/mainline/linux/patches/
  0221-fix-h616-pll-audio-hs-sdm-table-vco-rates.patch  # Fix 6 (SDM table VCO rates)
  0224-0701-armbian-h616-hdmi-audio.patch                # Fix 1 (Armbian import)
  0225-0702-h616-digital-audio-node.patch                # Fix 1 (companion)
  0226-sunxi_v2-ahub-hdmi-routing-fix.patch              # Fix 2 (AHUB routing)
  0227-dw-hdmi-force-hdmi-mode-on-audio-enable.patch     # Fix 3 (DVI mode)
```
