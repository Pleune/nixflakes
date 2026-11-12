{
  stdenv,
  strataPkg,
}:

# strata-prefetch's gyro family, through the real wrapper (the dry-run downloads nothing): the
# one-file layout, the pinned revision and sha256, the --compat-bf16 pack, the pack name, and the
# family/model pairings it must refuse.  Also a regression that the two-shard families still
# plan two shards - the shard count is per-quant now.
stdenv.mkDerivation {
  name = "strata-prefetch-gyro";

  nativeBuildInputs = [ strataPkg ];

  buildCommand = ''
    export HOME=$NIX_BUILD_TOP

    ${strataPkg}/bin/strata-prefetch --dry-run --family gyro --model Gyro-M \
      --data-dir $NIX_BUILD_TOP/data --vision cpu --vision-exe /bin/strata-vision > plan-m.txt
    grep -q "vision cpu" plan-m.txt
    # One file, at the revision setup.py pins, sha256-pinned to the Hub's LFS pointer.
    grep -q "agentionai/Qwen3.8-Flash-Next-Gyro-GGUF/resolve/1ada08422e404aca51ab9df665f089f34c419c6b" plan-m.txt
    grep -q "Qwen3.8-Flash-Next-Gyro-M-TQ2_0.gguf" plan-m.txt
    grep -q "sha256 7aa36d15131d255179ab6c87fa9c9f81a0b541fc9e81e959d4c3e29eb20feb5f" plan-m.txt
    # The ISTA shards' split names must not appear for a one-file family.
    if grep -q "of-00002" plan-m.txt; then
      echo "gyro ships one file per size, not two shards"; exit 1
    fi
    # The pack is named after family tag + size, and built --compat-bf16 (folded experts).
    grep -q "pack in $NIX_BUILD_TOP/data/packs/gyro-gyro-m" plan-m.txt
    grep -q -- "--compat-bf16" plan-m.txt
    # Gyro reads pictures with the original's encoder.
    grep -q "picture reader mmproj-Qwen3.8-Flash-Next-BF16.gguf" plan-m.txt
    grep -q "sha256 b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0" plan-m.txt

    ${strataPkg}/bin/strata-prefetch --dry-run --family gyro --model Gyro-S \
      --data-dir $NIX_BUILD_TOP/data --vision off > plan-s.txt
    grep -q "Qwen3.8-Flash-Next-Gyro-S-TQ1_0.gguf" plan-s.txt
    grep -q "sha256 c6ea1b08ca312f99095b27588ba35976b53f948268e7f91e7761926aa01d9c87" plan-s.txt
    grep -q "packs/gyro-gyro-s" plan-s.txt
    if grep -q "picture reader" plan-s.txt; then
      echo "vision off must fetch no picture reader"; exit 1
    fi

    # The ISTA families keep their two shards.
    ${strataPkg}/bin/strata-prefetch --dry-run --family swift --model IQ2_XS \
      --data-dir $NIX_BUILD_TOP/data --vision off > plan-swift.txt
    grep -q "00001-of-00002" plan-swift.txt
    grep -q "00002-of-00002" plan-swift.txt
    if grep -q -- "--compat-bf16" plan-swift.txt; then
      echo "--compat-bf16 belongs to gyro's folded experts only"; exit 1
    fi

    # A size is only published for its own family.
    if ${strataPkg}/bin/strata-prefetch --dry-run --family gyro --model IQ2_XS \
      --data-dir $NIX_BUILD_TOP/data --vision off > refuse-1.txt 2>&1; then
      echo "gyro does not publish IQ2_XS"; exit 1
    fi
    grep -q "only published for" refuse-1.txt

    if ${strataPkg}/bin/strata-prefetch --dry-run --family swift --model Gyro-M \
      --data-dir $NIX_BUILD_TOP/data --vision off > refuse-2.txt 2>&1; then
      echo "swift does not publish Gyro-M"; exit 1
    fi
    grep -q "only published for" refuse-2.txt

    touch $out
  '';
}
