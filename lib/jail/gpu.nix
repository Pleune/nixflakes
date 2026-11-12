{
  combinators,
  ...
}:
let
  inherit (combinators)
    add-runtime
    compose
    include-once
    ;
in
{
  sig = "Permission";
  doc = ''
    Exposes host GPUs to the jail. This replaces the upstream `gpu`
    combinator with a guarded, multi-vendor variant.

    This combinator:

      * Replaces `/sys` with an empty tmpfs and re-binds the read-only device
        views (`/sys/dev`, `/sys/bus`, `/sys/class`, `/sys/devices`), so PCI,
        DRM, and char-device enumeration works while debugfs, securityfs, and
        firmware stay out of the jail.
      * Binds `/dev/dri` when the host has it, which is what Vulkan, EGL,
        VA-API, and oneVPL need (render nodes are world-accessible on NixOS).
      * Binds `/dev/kfd` and every existing `/dev/nvidia*` node so AMD ROCm
        and NVIDIA CUDA work as well.
      * Binds `/proc/driver/nvidia` read-only when the NVIDIA driver exposes it,
        which NVML and `nvidia-smi` read.

    Every binding is guarded on the host path existing, so the same policy
    works on GPU-less hosts and on hosts whose driver only creates part of
    this tree - for example NVIDIA without `nvidia-drm`, where there is no
    `/dev/dri`. Userspace driver libraries come from `/run/opengl-driver`,
    which the shared sandbox policy already binds read-only along with `/`,
    so this combinator deliberately does not re-bind them.

    Device access still follows host node permissions: render nodes are
    world-accessible, while KMS card nodes are group `video` and `/dev/kfd`
    follows its udev mode. GPU access grants hardware access, not memory
    isolation: a jailed process can use the GPU and read host-visible
    hardware info, just like an unsandboxed process.
  '';
  impl = include-once "gpu" (compose [
    (add-runtime ''
      jailGpuBindIfPresent() {
        local flag path
        flag="$1"
        path="$2"

        if [ -e "$path" ]; then
          RUNTIME_ARGS+=("$flag" "$path" "$path")
        fi
        return 0
      }

      # Empty tmpfs first so host /sys submounts (debugfs, securityfs,
      # firmware) never reach the jail, then re-bind the device views ro.
      RUNTIME_ARGS+=(--tmpfs /sys)
      for JAIL_GPU_SYSFS in dev bus class devices; do
        jailGpuBindIfPresent --ro-bind "/sys/$JAIL_GPU_SYSFS" "/sys/$JAIL_GPU_SYSFS"
      done

      if [ -d /dev/dri ]; then
        RUNTIME_ARGS+=(--dev-bind /dev/dri /dev/dri)
      fi

      jailGpuBindIfPresent --dev-bind /dev/kfd

      for JAIL_GPU_NODE in /dev/nvidia*; do
        if [ -e "$JAIL_GPU_NODE" ]; then
          RUNTIME_ARGS+=(--dev-bind "$JAIL_GPU_NODE" "$JAIL_GPU_NODE")
        fi
      done

      jailGpuBindIfPresent --ro-bind /proc/driver/nvidia
    '')
  ]);
}
