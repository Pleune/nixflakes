# https://discourse.nixos.org/t/please-help-me-package-azureblobstorage/31562/3

{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libxcb,
  libxkbcommon,
  mesa,
  nspr,
  nss,
  pango,
  libglvnd,
  libsecret,
  systemd,
  dotnet-runtime_10,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "azure-storage-explorer";
  version = "1.43.0";

  src = fetchurl {
    url = "https://github.com/microsoft/AzureStorageExplorer/releases/download/v${finalAttrs.version}/StorageExplorer-linux-x64.tar.gz";
    hash = "sha256-Q+P5M/NjUezRY6SUdSkKBybXmmhOq5MOy5Zzq0tMFdc=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
    libxkbcommon
    mesa
    nspr
    nss
    pango
    libglvnd
    libsecret
    systemd
  ];

  runtimeDependencies = [
    systemd
  ];

  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -d $out/lib/azure-storage-explorer
    cp -r . $out/lib/azure-storage-explorer

    install -Dm644 \
      resources/app/out/app/media/StorageExplorerColor.svg \
      $out/share/icons/hicolor/scalable/apps/azure-storage-explorer.svg

    install -Dm644 /dev/stdin $out/share/applications/azure-storage-explorer.desktop <<EOF
    [Desktop Entry]
    Name=Azure Storage Explorer
    Comment=Microsoft Azure Storage Explorer
    Exec=storage-explorer
    Icon=$out/share/icons/hicolor/scalable/apps/azure-storage-explorer.svg
    Type=Application
    Categories=Development;Utility;
    EOF

    makeWrapper \
      $out/lib/azure-storage-explorer/StorageExplorerExe \
      $out/bin/storage-explorer \
      --add-flags "--no-sandbox" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libsecret ]}" \
      --set DOTNET_ROOT "${dotnet-runtime_10.unwrapped}/share/dotnet"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Microsoft Azure Storage Explorer - manage Azure cloud storage resources";
    homepage = "https://azure.microsoft.com/en-us/products/storage/storage-explorer/";
    license = licenses.unfree;
    mainProgram = "storage-explorer";
    platforms = [ "x86_64-linux" ];
  };
})