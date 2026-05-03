# Set HW_DEVICE from device-tree compatible string. ROCKNIX hardcodes
# HW_DEVICE in /etc/os-release at image-build time (per their
# scripts/image:163 — `HW_DEVICE="${DEVICE}"`); we derive it at boot
# from /sys/firmware/devicetree/base/compatible so a single image works
# across the whole H700 family without per-device os-release files.
#
# Numbered 045 so it runs AFTER 002-autostart (which sets QUIRK_DEVICE
# from /sys/firmware/devicetree/base/model) and BEFORE 099-freqfunctions
# / 100-gamecontroller-functions (which read both QUIRK_DEVICE and
# HW_DEVICE).
#
# Map device-tree compat → HW_DEVICE name used by quirks/platforms/<HW_DEVICE>/.

if [ -r /sys/firmware/devicetree/base/compatible ]; then
    _compat=$(tr '\0' '\n' < /sys/firmware/devicetree/base/compatible)

    case "$_compat" in
        *allwinner,sun50i-h700*)  export HW_DEVICE=H700 ;;
        *allwinner,sun50i-a133*)  export HW_DEVICE=A133 ;;
        *rockchip,rk3566*)        export HW_DEVICE=RK3566 ;;
        *rockchip,rk3326*)        export HW_DEVICE=RK3326 ;;
        *rockchip,rk3399*)        export HW_DEVICE=RK3399 ;;
        *rockchip,rk3588*)        export HW_DEVICE=RK3588 ;;
        *amlogic,s922x*)          export HW_DEVICE=S922X ;;
        *qcom,sm6115*)            export HW_DEVICE=SM6115 ;;
        *qcom,sm8250*)            export HW_DEVICE=SM8250 ;;
        *qcom,sm8550*)            export HW_DEVICE=SM8550 ;;
        *qcom,sm8650*)            export HW_DEVICE=SM8650 ;;
    esac

    unset _compat
fi
