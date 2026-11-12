#!/bin/sh
# Construit le paquet d'installation universel (Apple Silicon + Intel) du pont AirScan DS-720D.
set -e
VERSION="${VERSION:-1.1.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOP="$HERE/.."
BUILD="$HERE/build"
OUT="$HERE/dist/DS720D-AirScan-$VERSION.pkg"

make -C "$TOP/usbd"
make -C "$TOP/airscan"
make -C "$TOP/agent"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$HERE/dist"
cp -R "$HERE/root" "$BUILD/root"
mkdir -p "$BUILD/root/Library/PrivilegedHelperTools"
install -m 755 "$TOP/usbd/ds720d-usbd" "$BUILD/root/Library/PrivilegedHelperTools/local.ds720d.usbd"
install -m 755 "$TOP/airscan/ds720d-airscan" "$BUILD/root/usr/local/libexec/ds720d/ds720d-airscan"
install -m 755 "$TOP/agent/ds720d-agent" "$BUILD/root/usr/local/libexec/ds720d/ds720d-agent"
chmod 755 "$BUILD/root/usr/local/libexec/ds720d/uninstall.sh" "$HERE/scripts/preinstall" "$HERE/scripts/postinstall"
# Modes des dossiers identiques à ceux du système (et l'installateur ne les réécrit pas, voir plus bas).
chmod 755 "$BUILD/root/Library" "$BUILD/root/Library/LaunchAgents" "$BUILD/root/Library/LaunchDaemons" \
          "$BUILD/root/usr" "$BUILD/root/usr/local" "$BUILD/root/usr/local/libexec" "$BUILD/root/usr/local/libexec/ds720d"
chmod 1755 "$BUILD/root/Library/PrivilegedHelperTools"
find "$BUILD/root" -name .DS_Store -delete
xattr -cr "$BUILD/root" "$HERE/scripts"   # sinon pkgbuild ajoute des fichiers AppleDouble « ._* »
export COPYFILE_DISABLE=1

pkgbuild --root "$BUILD/root" --scripts "$HERE/scripts" --identifier local.ds720d.airscan \
         --version "$VERSION" --install-location / --ownership recommended \
         "$BUILD/raw-component.pkg"

# L'attribut protégé com.apple.provenance ne peut pas être retiré et pkgbuild le transforme en fichiers
# « ._* ». On régénère donc la charge utile (cpio odc, sans attributs étendus) et sa nomenclature (BOM).
pkgutil --expand "$BUILD/raw-component.pkg" "$BUILD/exp"
(cd "$BUILD/root" && find . | sort | cpio -o --format odc -R 0:0 2>/dev/null) | gzip -9 > "$BUILD/exp/Payload"
mkbom "$BUILD/root" "$BUILD/tmp.bom"
lsbom "$BUILD/tmp.bom" | awk -F'\t' 'BEGIN{OFS="\t"} {$3="0/0"; print}' > "$BUILD/bom.txt"
rm -f "$BUILD/exp/Bom" && mkbom -i "$BUILD/bom.txt" "$BUILD/exp/Bom"
NFILES=$(cd "$BUILD/root" && find . | wc -l | tr -d ' ')
KBYTES=$(du -sk "$BUILD/root" | cut -f1)
sed -i '' -E "s/numberOfFiles=\"[0-9]+\"/numberOfFiles=\"$NFILES\"/; s/installKBytes=\"[0-9]+\"/installKBytes=\"$KBYTES\"/" "$BUILD/exp/PackageInfo"
# Ne pas réécrire les permissions des dossiers système existants (/Library, /usr/local…).
sed -i '' 's/overwrite-permissions="true"/overwrite-permissions="false"/' "$BUILD/exp/PackageInfo"
pkgutil --flatten "$BUILD/exp" "$BUILD/ds720d-airscan-component.pkg"
rm "$BUILD/raw-component.pkg"
sed "s/VERSION/$VERSION/" "$HERE/Distribution.xml" > "$BUILD/Distribution.xml"
productbuild --distribution "$BUILD/Distribution.xml" --resources "$HERE/resources" \
             --package-path "$BUILD" "$OUT"
echo "Paquet : $OUT"
